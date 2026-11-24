package rulescript.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using StringTools;
#end

class RuleScriptInlineMacro 
{
	public static function init() 
	{
		#if macro
		Context.onAfterTyping(onAfterTyping);
		#end
	}

	#if macro
	static function onAfterTyping(types:Array<ModuleType>):Void 
	{
		for (type in types) 
		{
			switch (type) 
			{
				case TClassDecl(c):
					final cls = c.get();
					if (cls.isPrivate || cls.isExtern || cls.isInterface || cls.kind.match(KAbstractImpl(_))) continue;

					final seenNames:Array<String> = [];
					final fields = generateInlineWrappers(cls.fields.get(), cls, null, false, seenNames)
						.concat(generateInlineWrappers(cls.statics.get(), cls, null, true, seenNames));

					if (fields.length > 0) 
					{
						Context.defineType({
							pos: cls.pos,
							pack: ['rulescript', '_internal', 'classes'].concat(cls.pack),
							name: '${cls.name}_RuleScriptImpl_',
							kind: TDClass(null, [], false, false, false),
							fields: fields,
							meta: [{name: ':keep', pos: cls.pos}]
						}, 'rulescript.macro.RuleScriptInlineMacro');
					}

				case TAbstract(a):
					final abs = a.get();
					if (abs.impl == null || abs.isPrivate) continue;

					final implType = abs.impl.get();
					if (implType.isExtern) continue;

					final seenNames:Array<String> = [];
					final fields = generateInlineWrappers(implType.statics.get(), abs, abs, true, seenNames);
					if (fields.length > 0) 
					{
						Context.defineType({
							pos: abs.pos,
							pack: ['rulescript', '_internal', 'abstracts'].concat(abs.pack),
							name: '${abs.name}_RuleScriptImpl_',
							kind: TDClass(null, [], false, false, false),
							fields: fields,
							meta: [{name: ':keep', pos: abs.pos}]
						}, 'rulescript.macro.RuleScriptInlineMacro');
					}
				default:
			}
		}
	}

	static function buildTypeFieldExpr(typeDef:BaseType, fieldName:String, pos:Position):Expr
	{
		final parts = typeDef.module.split('.');
		var e:Expr = {expr: EConst(CIdent(parts[0])), pos: pos};
		for (i in 1...parts.length)
			e = {expr: EField(e, parts[i]), pos: pos};
		if (parts[parts.length - 1] != typeDef.name)
			e = {expr: EField(e, typeDef.name), pos: pos};
		return {expr: EField(e, fieldName), pos: pos};
	}

	static function isSpecialAbstractField(abs:AbstractType, field:ClassField):Bool
	{
		if (field.name == 'new' || field.name == '_new' || field.name == '__new' || field.name == '_hx_new')
			return true;
		if (abs.resolve != null && abs.resolve.name == field.name)
			return true;
		#if (haxe_ver >= 4.200)
		if (abs.resolveWrite != null && abs.resolveWrite.name == field.name)
			return true;
		#end
		for (a in abs.array)
			if (a.name == field.name) return true;

		for (list in ([abs.from, abs.to, abs.binops, abs.unops] : Array<Array<Dynamic>>))
			for (entry in list)
				if (entry.field != null && entry.field.name == field.name) return true;

		return false;
	}

	static function generateInlineWrappers(fields:Array<ClassField>, typeDef:BaseType, abs:Null<AbstractType>, isStatic:Bool, seenNames:Array<String>):Array<Field> 
	{
		if (typeDef.params.length > 0) return [];

		final fullPath = typeDef.pack.concat([typeDef.name]).join('.');

		if (fullPath.indexOf('flixel.graphics.atlas.HashOrArray') != -1 || fullPath.startsWith('cpp') || fullPath.startsWith('hl')) 
			return [];

		final keepPrivates = !fullPath.startsWith('haxe.') && !fullPath.startsWith('sys.');
		final genFields:Array<Field> = [];

		final allProps = [
			for (f in fields)
				if (f.kind.match(FVar(_, _))) f.name
		];

		for (field in fields) 
		{
			if (field.params.length > 0 || field.isExtern) continue;
			if (abs != null && isSpecialAbstractField(abs, field)) continue;

			final pos = field.pos;

			if (!field.isPublic && keepPrivates && !field.meta.has(':keep'))
				field.meta.add(':keep', [], pos);

			if (isStatic && field.kind.match(FVar(AccInline, _)))
			{
				if (seenNames.contains(field.name)) continue;
				seenNames.push(field.name);

				final targetExpr = buildTypeFieldExpr(typeDef, field.name, pos);
				genFields.push({
					pos: pos,
					name: field.name,
					access: [APublic, AStatic],
					kind: FVar(macro :Dynamic, macro @:privateAccess $targetExpr),
					meta: [{name: ':keep', pos: pos}, {name: ':noCompletion', pos: pos}]
				});
				continue;
			}

			final isGetterOrSetterName = field.name.startsWith('get_') || field.name.startsWith('set_');
			final isClassAccessor = abs == null && isGetterOrSetterName && allProps.contains(field.name.substr(4));
			final isAbstractAccessor = abs != null && isGetterOrSetterName;
			final isAccessor = isClassAccessor || isAbstractAccessor;

			if (field.kind.match(FMethod(MethInline))) 
			{
				switch (field.type) 
				{
					case TFun(args, ret):
						final isAbstractMember = abs != null && (
							field.meta.has(':impl')
							|| (args.length > 0 && ~/^this\d*$/.match(args[0].name))
						);
						if (isAbstractMember && args.length == 0) continue;

						final hasThis = !isStatic || isAbstractMember;
						final isVoid = haxe.macro.TypeTools.toString(ret) == 'Void';
						final actualArgs = isAbstractMember ? args.slice(1) : args;

						final fieldArgs:Array<FunctionArg> = [];
						final callArgsExpr:Array<Expr> = [];
						for (i in 0...actualArgs.length)
						{
							final rawName = actualArgs[i].name;
							final safeName = (rawName == null || rawName == '' || ~/^this\d*$/.match(rawName)) ? '__arg$i' : rawName;
							fieldArgs.push({name: safeName, type: null});
							callArgsExpr.push({expr: EConst(CIdent(safeName)), pos: pos});
						}

						if (hasThis)
						{
							final typePath = TPath({
								pack: typeDef.pack,
								name: typeDef.module.split('.').pop(),
								sub: typeDef.name,
								params: []
							});

							final bodyExpr:Expr = if (isAbstractAccessor)
							{
								if (!isAbstractMember) continue;
								final propName = field.name.substr(4);
								final propExpr = {expr: EField(macro __typedThis, propName), pos: pos};
								if (field.name.startsWith('get_'))
									macro {
										var __typedThis = (__this : $typePath);
										return @:privateAccess $propExpr;
									}
								else if (callArgsExpr.length == 1)
								{
									final valExpr = callArgsExpr[0];
									macro {
										var __typedThis = (__this : $typePath);
										return @:privateAccess ($propExpr = $valExpr);
									}
								}
								else
									continue;
							}
							else
							{
								final targetExpr = {expr: EField(macro __typedThis, field.name), pos: pos};
								final callExpr = {expr: ECall(targetExpr, callArgsExpr), pos: pos};
								isVoid
									? macro {
										var __typedThis = (__this : $typePath);
										@:privateAccess $callExpr;
										return null;
									}
									: macro {
										var __typedThis = (__this : $typePath);
										return @:privateAccess $callExpr;
									};
							};

							if (seenNames.contains(field.name)) continue;
							seenNames.push(field.name);

							genFields.push({
								pos: pos,
								name: field.name,
								access: [APublic, AStatic],
								kind: FFun({
									args: [{name: '__this', type: macro :Dynamic}].concat(fieldArgs),
									ret: macro :Dynamic,
									expr: bodyExpr
								}),
								meta: [{name: ':keep', pos: pos}, {name: ':noCompletion', pos: pos}]
							});
						}
						else
						{
							if (seenNames.contains(field.name)) continue;
							seenNames.push(field.name);

							final targetExpr = buildTypeFieldExpr(typeDef, field.name, pos);
							final callExpr = {expr: ECall(targetExpr, callArgsExpr), pos: pos};

							genFields.push({
								pos: pos,
								name: field.name,
								access: [APublic, AStatic],
								kind: FFun({
									args: fieldArgs,
									ret: macro :Dynamic,
									expr: isVoid
										? macro {
											@:privateAccess $callExpr;
											return null;
										}
										: macro return @:privateAccess $callExpr
								}),
								meta: [{name: ':keep', pos: pos}, {name: ':noCompletion', pos: pos}]
							});
						}
					default:
				}
			}
		}
		return genFields;
	}
	#end
}