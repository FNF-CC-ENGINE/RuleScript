package rulescript.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

import sys.FileSystem;
import sys.io.File;

using StringTools;

class TypedefMacro
{
	macro public static function build():Array<Field>
	{
		final defaultFilename:String = 'RuleScriptTypedefs.txt';
		final filename:String = Context.definedValue('rulescript_typedefs_file_path');

		final typedefsList:Array<String> = [];
		final ignoreList:Array<String> = [];

		for (dir in Context.getClassPath())
		{
			for (name in (filename != null ? [defaultFilename, filename] : [defaultFilename]))
			{
				if (FileSystem.exists(dir + name))
				{
					for (item in parseFile(File.getContent(dir + name)))
					{
						if (item.startsWith('#') || item.startsWith('//') || item.length == 0) {}
						else if (item.startsWith('-#'))
							ignoreList.push(item);
						else if (!typedefsList.contains(item))
							typedefsList.push(item);
					}
				}
			}
		}

		final mapEntries:Array<Expr> = [
			for (typedefPath in typedefsList)
			{
				if (!ignoreList.contains('-#$typedefPath'))
					resolveTypedef(typedefPath);
			}
		];

		mapEntries.push(macro "haxe.Int32" => Int);
		mapEntries.push(macro "rulescript.BytecodeInterp" => rulescript.interps.BytecodeInterp);
		mapEntries.push(macro "rulescript.Parser" => rulescript.parsers.Parser);
		mapEntries.push(macro "rulescript.HxParser" => rulescript.parsers.HxParser);

		#if hl
		mapEntries.push(macro "rulescript.Reflect" => rulescript.std.hl.Reflect);
		mapEntries.push(macro "rulescript.Math" => rulescript.std.hl.Math);
		mapEntries.push(macro "rulescript.Std" => rulescript.std.hl.Std);
		#end

		final fields = Context.getBuildFields();
		fields.push({
			name: 'typedefs',
			access: [APublic, AStatic],
			kind: FVar(macro :Map<String, Dynamic>, macro [ $a{mapEntries} ]),
			pos: Context.currentPos()
		});
		return fields;
	}

	static function resolveTypedef(path:String):Expr
	{
		try
		{
			final t = Context.getType(path);
			final followed = Context.follow(t);

			switch (followed)
			{
				case TInst(cls, _):
					final clsRef = cls.get();
					final fullClassPath = clsRef.pack.concat([clsRef.name]).join('.');
					return macro $v{path} => Type.resolveClass($v{fullClassPath});

				case TEnum(en, _):
					final enRef = en.get();
					final fullEnumPath = enRef.pack.concat([enRef.name]).join('.');
					return macro $v{path} => Type.resolveEnum($v{fullEnumPath});

				default:
			}
		}
		catch (e:Dynamic)
		{
			Context.warning('Error resolving typedef $path: $e', Context.currentPos());
		}
		return macro $v{path} => null;
	}

	static function parseFile(content:String):Array<String>
	{
		final lines = content.replace('\r', '').split('\n');
		var active = true;
		var result:Array<String> = [];
		var conditionMet = false;
		var stack:Array<{active:Bool, conditionMet:Bool}> = [];
		
		for (line in lines)
		{
			var trimmed = line.trim();
			
			if (trimmed.startsWith('#if '))
			{
				stack.push({active: active, conditionMet: conditionMet});
				var condition = trimmed.substr(4).trim();
				active = evaluateCondition(condition) && active;
				conditionMet = active;
			}
			else if (trimmed.startsWith('#elseif '))
			{
				if (conditionMet)
				{
					active = false;
				}
				else
				{
					var condition = trimmed.substr(8).trim();
					active = evaluateCondition(condition) && stack[stack.length - 1].active;
					conditionMet = active;
				}
			}
			else if (trimmed == '#else')
			{
				active = stack[stack.length - 1].active && !conditionMet;
				conditionMet = true;
			}
			else if (trimmed == '#end')
			{
				var state = stack.pop();
				if (state != null)
				{
					active = state.active;
					conditionMet = state.conditionMet;
				}
			}
			else if (active && trimmed.length > 0)
			{
				if (trimmed.startsWith('-#'))
					result.push(trimmed);
				else if (!trimmed.startsWith('//'))
					result.push(trimmed.replace(' ', ''));
			}
		}
		
		return result;
	}

	static function evaluateCondition(condition:String):Bool
	{
		var tokens = tokenize(condition);
		var pos = 0;
		
		function peek():{type:String, value:String} return tokens[pos];
		
		function consume(type:String, ?value:String):{type:String, value:String}
		{
			var token = peek();
			if (token == null)
				Context.error('Unexpected end of condition: $condition', Context.currentPos());
			if (token.type != type)
				Context.error('Expected token of type $type, but got ${token.type} in condition: $condition', Context.currentPos());
			if (value != null && token.value != value)
				Context.error('Expected token with value $value, but got ${token.value} in condition: $condition', Context.currentPos());
			pos++;
			return token;
		}
		
		var parseExpression:Void->Bool = null;
		var parseOr:Void->Bool = null;
		var parseAnd:Void->Bool = null;
		var parseComparison:Void->Bool = null;
		var parseUnary:Void->Bool = null;
		var parsePrimary:Void->Bool = null;
		
		parsePrimary = function():Bool
		{
			if (peek() == null)
				Context.error('Unexpected end of condition in condition: $condition', Context.currentPos());
			
			if (peek().type == "(")
			{
				consume("(");
				var res = parseExpression();
				consume(")");
				return res;
			}
			else if (peek().type == "id")
			{
				var token = consume("id");
				return Context.defined(token.value);
			}
			else if (peek().type == "num")
			{
				var token = consume("num");
				return Std.parseFloat(token.value) != 0;
			}
			else if (peek().type == "str")
			{
				var token = consume("str");
				return token.value != "";
			}
			else
			{
				Context.error('Unexpected token ${peek().type} in condition: $condition', Context.currentPos());
				return false;
			}
		}
		
		parseUnary = function():Bool
		{
			if (peek() != null && peek().type == "op" && peek().value == "!")
			{
				consume("op", "!");
				return !parseUnary();
			}
			return parsePrimary();
		}
		
		parseComparison = function():Bool
		{
			var left = parseUnary();
			while (peek() != null && peek().type == "cmp")
			{
				var op = consume("cmp").value;
				var right = parseUnary();
				
				switch (op)
				{
					case "==": left = left == right;
					case "!=": left = left != right;
					default:
						Context.error('Unknown comparison operator: $op', Context.currentPos());
				}
			}
			return left;
		}
		
		parseAnd = function():Bool
		{
			var left = parseComparison();
			while (peek() != null && peek().type == "op" && peek().value == "&&")
			{
				consume("op", "&&");
				var right = parseComparison();
				left = left && right;
			}
			return left;
		}
		
		parseOr = function():Bool
		{
			var left = parseAnd();
			while (peek() != null && peek().type == "op" && peek().value == "||")
			{
				consume("op", "||");
				var right = parseAnd();
				left = left || right;
			}
			return left;
		}
		
		parseExpression = function():Bool return parseOr();
		
		return parseExpression();
	}

	static function tokenize(condition:String):Array<{type:String, value:String}>
	{
		var tokens:Array<{type:String, value:String}> = [];
		var i = 0;
		var length = condition.length;
		
		while (i < length)
		{
			var c = condition.charAt(i);
			
			if (c == ' ') { i++; continue; }
			
			if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')
			{
				var start = i;
				while (i < length && 
				      ((condition.charAt(i) >= 'a' && condition.charAt(i) <= 'z') ||
					   (condition.charAt(i) >= 'A' && condition.charAt(i) <= 'Z') ||
					   (condition.charAt(i) >= '0' && condition.charAt(i) <= '9') ||
					   condition.charAt(i) == '_'))
				{
					i++;
				}
				tokens.push({type: "id", value: condition.substring(start, i)});
				continue;
			}
			
			if (c >= '0' && c <= '9')
			{
				var start = i;
				var dot = false;
				while (i < length && 
				      (condition.charAt(i) >= '0' && condition.charAt(i) <= '9') ||
					  (!dot && condition.charAt(i) == '.'))
				{
					if (condition.charAt(i) == '.') dot = true;
					i++;
				}
				tokens.push({type: "num", value: condition.substring(start, i)});
				continue;
			}
			
			if (c == '"' || c == "'")
			{
				var quote = c;
				var start = i;
				i++;
				while (i < length && condition.charAt(i) != quote) i++;
				tokens.push({type: "str", value: condition.substring(start + 1, i)});
				i++;
				continue;
			}
			
			if (c == '&' && i + 1 < length && condition.charAt(i + 1) == '&')
			{
				tokens.push({type: "op", value: "&&"});
				i += 2;
				continue;
			}
			
			if (c == '|' && i + 1 < length && condition.charAt(i + 1) == '|')
			{
				tokens.push({type: "op", value: "||"});
				i += 2;
				continue;
			}
			
			if (c == '!')
			{
				if (i + 1 < length && condition.charAt(i + 1) == '=')
				{
					tokens.push({type: "cmp", value: "!="});
					i += 2;
				}
				else
				{
					tokens.push({type: "op", value: "!"});
					i++;
				}
				continue;
			}
			
			if (c == '=')
			{
				if (i + 1 < length && condition.charAt(i + 1) == '=')
				{
					tokens.push({type: "cmp", value: "=="});
					i += 2;
				}
				else
				{
					tokens.push({type: "op", value: "="});
					i++;
				}
				continue;
			}
			
			if (c == '(') { tokens.push({type: "(", value: "("}); i++; continue; }
			if (c == ')') { tokens.push({type: ")", value: ")"}); i++; continue; }
			
			i++;
		}
		
		return tokens;
	}
}
#end