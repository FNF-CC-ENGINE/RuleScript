package rulescript.scriptedClass;

import hscript.Expr;
import hscript.Expr.ClassDecl;
import hscript.Expr.FieldKind;

import rulescript.RuleScript.IInterp;
import rulescript.Tools.TypePath;
import rulescript.interps.RuleScriptInterp;
import rulescript.types.ScriptedModule;
import rulescript.types.ScriptedType;

@:autoBuild(rulescript.macro.RuleScriptedClassMacro.build())
interface RuleScriptedClass extends ScriptedType
{
	function getVariables():Map<String, Dynamic>;
	function variableExists(name:String):Bool;
	function getVariable(name:String):Dynamic;
	function setVariable(name:String, value:Dynamic):Dynamic;
}

@:forward
abstract Access(RuleScriptedClass)
{
	/**
	 * Returns the contents of the wrapper with the given type
	 * 
	 * @param t The given type.
	 * @return T
	 */
	inline public function self<T:RuleScriptedClass>(?t:T):T
	{
		return cast this;
	}

	/**
	 * The constructor of the scripted class, this is also referred to as `new`. 
	 */
	public var constructor(get, set):(args:Array<Dynamic>) -> Dynamic;

	public function new(cl:RuleScriptedClass)
	{
		this = cl;
	}

	@:op(a.b)
	inline function get(variable:String):Dynamic
	{
		return this.getVariable(variable);
	}

	@:op(a.b)
	inline function set(variable:String, value:Dynamic):Dynamic
	{
		return this.setVariable(variable, value);
	}

	/**
	 * This method allows you to create an instance of a scripted class.
	 * If unsuccessful, it'll throw an error. 
	 * 
	 * @param args The scripted class instance arguments. (This is an optional parameter)
	 * @return Returns an instance of `Access`.
	 */
	inline public function createInstance(?args:Array<Dynamic>):Access
	{
		return abstract is ScriptedClass ? cast(this, ScriptedClass).createInstance(args) : throw 'createInstance is only allowed for ScriptedClass';
	}

	inline function get_constructor():Array<Dynamic>->Dynamic
	{
		return abstract is ScriptedClass ? cast(this, ScriptedClass).initialize : throw 'Constructor is only allowed for ScriptedClass';
	}

	inline function set_constructor(value:Array<Dynamic>->Dynamic):Array<Dynamic>->Dynamic
	{
		return abstract is ScriptedClass ? cast(this, ScriptedClass).initialize = value : throw 'Constructor is only allowed for ScriptedClass';
	}
}

@:access(rulescript.RuleScriptAccess)
@:noBuild class ScriptedClass implements RuleScriptedClass
{
	public var className:String;
	public var module:ScriptedModule;
	public var impl:ClassDecl;

	public var superClass:Null<Dynamic>;
	public var nativeClass:Null<Dynamic>;

	var interp:IInterp;

	public var initialize:(args:Array<Dynamic>) -> Dynamic;

	#if !js
	@:deprecated('ScriptedClass.constructor was moved to ScriptedClass.createInstance')
	public var constructor(get, set):(args:Array<Dynamic>) -> Dynamic;

	inline function get_constructor():(args:Array<Dynamic>) -> Dynamic
	{
		return initialize;
	}

	inline function set_constructor(f:(args:Array<Dynamic>) -> Dynamic):(args:Array<Dynamic>) -> Dynamic
	{
		return initialize = f;
	}
	#end

	public function new(impl:ClassDecl, module:ScriptedModule)
	{
		this.impl = impl;
		this.module = module;

		className = impl.name;

		interp = RuleScript.createInterp();
		@:privateAccess interp.access.context = module.context;
		interp.access.setVariable(className, this);
	}

	var initialized:Bool = false;

	@:allow(rulescript.types.ScriptedModule)
	function init()
	{
		if (initialized)
			return;
		else
			initialized = true;

		for (name => type in module.types)
		{
			interp.access.setVariable(name, type);
		}

		if (interp is RuleScriptInterp)
			RuleScriptedClassUtil.applyImportsFromDecls(cast interp, module.sharedDecls);

		interp.access.execute(Tools.moduleDeclsToExpr(module.sharedDecls, {
			fieldFilter: f -> f.access.contains(AStatic),
			classImpl: impl
		}));

		RuleScriptedClassUtil.registerRuleScriptedClass(toString(), this);

		if (impl.extend != null)
		{
			var type = Tools.typeToString(impl.extend);

			@:privateAccess {
				// Check module
				superClass ??= module.types[type];
				// Check type
				superClass ??= interp.access.__resolveType(type);
				// Check imported types
				superClass ??= interp.access.__resolve(type);
			}

			if (superClass == null)
				throw 'Type not found : $type';
		}

		if (superClass != null)
		{
			if (superClass is ScriptedClass)
			{
				superClass.init();
				nativeClass = superClass.nativeClass;
			}
			else
			{
				nativeClass = superClass;
			}
		}

		initialize = if (nativeClass == null && (superClass == null || superClass is ScriptedClass))
			function(args) { return new ScriptedInstance(this, args); }
		else if (nativeClass != null)
		{
			final type = toString();

			var wrapperStrict:Null<Bool> = null;
			try
			{
				final v = Reflect.field(nativeClass, '__rulescript_strict');
				if (v != null) wrapperStrict = v == true;
			}
			catch (e:Dynamic) {}

			if (wrapperStrict == null)
			{
				args -> #if rulescript_use_hl_fixes
					Tools.__hl_createInstance(nativeClass, args);
				#else
					Type.createInstance(nativeClass, args);
				#end
			}
			else if (wrapperStrict)
			{
				args ->
				{
					var strictArgs:Array<Dynamic> = [type];
					for (arg in args) strictArgs.push(arg);
					#if rulescript_use_hl_fixes
					Tools.__hl_createInstance(nativeClass, strictArgs);
					#else
					Type.createInstance(nativeClass, strictArgs);
					#end
				}
			}
			else
			{
				args ->
					#if rulescript_use_hl_fixes
					Tools.__hl_createInstance(nativeClass, [type, args]);
					#else
					Type.createInstance(nativeClass, [type, args]);
					#end
			}
		}
		else
			(_) -> throw toString() + ' cannot be constructed';

		interp.access.scriptName = toString();
	}

	public function getVariables():Map<String, Dynamic>
	{
		init();
		var vars:Map<String, Dynamic> = [];
		for (k => v in interp.access.getVariables()) vars.set(k, v);

		if (module.context != null) {
			for (k => v in module.context.staticVariables) vars.set(k, v);
			for (k => v in module.context.publicVariables) vars.set(k, v);
		}
		return vars;
	}

	public function variableExists(name:String):Bool
	{
		init();
		return interp.access.variableExists(name)
			|| (module.context != null
				&& (module.context.staticVariables.exists(name) || module.context.publicVariables.exists(name)));
	}

	public function getVariable(name:String):Dynamic
	{
		init();
		if (module.context != null) {
			if (module.context.staticVariables.exists(name))
				return module.context.staticVariables.get(name);
			if (module.context.publicVariables.exists(name))
				return module.context.publicVariables.get(name);
		}
		if (interp.access.variableExists(name))
			return interp.access.getVariable(name);
		return null;
	}

	public function setVariable(name:String, value:Dynamic):Dynamic
	{
		init();
		if (module.context != null) {
			if (module.context.staticVariables.exists(name)) {
				module.context.staticVariables.set(name, value);
				if (interp.access.variableExists(name))
					interp.access.setVariable(name, value);
				return value;
			}
			if (module.context.publicVariables.exists(name)) {
				module.context.publicVariables.set(name, value);
				if (interp.access.variableExists(name))
					interp.access.setVariable(name, value);
				return value;
			}
		}
		return interp.access.setVariable(name, value);
	}

	@:noCompletion public var __rulescript_type(get, never):TypeID;

	private function get___rulescript_type():TypeID
	{
		return CLASS;
	}

	public function hasScriptFunction(name:String):Bool
	{
		if (impl == null || impl.fields == null) return false;
		for (field in impl.fields)
		{
			if (field.name == name && !field.access.contains(AStatic))
			{
				switch (field.kind)
				{
					case KFunction(_): return true;
					default:
				}
			}
		}
		return false;
	}

	public function getParentScriptedClass():Null<ScriptedClass>
	{
		try { init(); } catch (e:Dynamic) { return null; }
		return (superClass is ScriptedClass) ? cast superClass : null;
	}

	public function createInstance(args:Array<Dynamic>):Dynamic
	{
		init();

		if (impl?.extend != null)
		{
			final extendName = rulescript.Tools.typeToString(impl.extend);
			final shortName = extendName.split(".").pop();

			final wrapperClass = RuleScriptedClassUtil.autoWrappers.get(extendName)
							 ?? RuleScriptedClassUtil.autoWrappers.get(shortName);

			if (wrapperClass != null)
			{
				final isStrict:Bool = Reflect.field(wrapperClass, "__rulescript_strict") == true;
				final scriptName = this.toString();

				try {
					if (isStrict) {
						final wrapperArgs:Array<Dynamic> = [scriptName];
						if (args != null) for (a in args) wrapperArgs.push(a);
						return Type.createInstance(wrapperClass, wrapperArgs);
					} else {
						return Type.createInstance(wrapperClass, [scriptName, args ?? []]);
					}
				} catch(e:Dynamic) {
					trace('Scripted Class Error: Failed to create wrapper for "' + shortName + '": ' + e);
					return null;
				}
			}
		}

		if (nativeClass != null) {
			try {
				return Type.createInstance(nativeClass, args ?? []);
			} catch(e:Dynamic) {
				trace('Scripted Class Error: Failed to create native fallback class for "' + toString() + '": ' + e);
			}
		}

		initialize(args ?? []);
		return interp.access.superInstance ?? this;
	}

	@:access(rulescript.RuleScriptAccess)
	public function toString():String
	{
		return if (variableExists('toString'))
			getVariable('toString')();
		else
		{
			TypePath.createString(interp.access.scriptPackage.split('.'), module.name, impl.name);
		}
	}
}

@:access(rulescript.RuleScriptAccess)
@:access(rulescript.types.ScriptedClass)
@:noBuild class ScriptedInstance implements RuleScriptedClass
{
	var cl:ScriptedClass;
	public var interp:IInterp;
	public var variables(get, set):Map<String, Dynamic>;

	public function new(cl:ScriptedClass, args:Array<Dynamic>)
	{
		this.cl = cl;

		interp = RuleScript.createInterp();
		interp.access.scriptName = cl.toString();

		final list:Array<ScriptedClass> = [];
		var currentClass:Dynamic = cl;

		while (currentClass != null)
		{
			if (currentClass is ScriptedClass)
			{
				final sc:ScriptedClass = cast currentClass;
				list.insert(0, sc);
				setVariable(sc.className, sc);
				currentClass = sc.superClass;
			}
			else
			{
				setVariable(Type.getClassName(currentClass), currentClass);
				break;
			}
		}

		for (i in 0...list.length)
		{
			final targetClass = list[i];

			if (i > 0 && targetClass.impl?.fields != null)
			{
				for (field in targetClass.impl.fields)
				{
					if (field.access.contains(AStatic)) continue;
					switch (field.kind)
					{
						case KFunction(_):
							final superName = '__super_' + field.name;
							try
							{
								if (!interp.access.variableExists(superName)
									&& interp.access.variableExists(field.name))
								{
									final parentFn = interp.access.getVariable(field.name);
									if (parentFn != null)
										interp.access.setVariable(superName, parentFn);
								}
							}
							catch (e:Dynamic) {}
						default:
					}
				}
			}

			if (interp is RuleScriptInterp)
				RuleScriptedClassUtil.applyImportsFromDecls(cast interp, targetClass.module.sharedDecls);

			interp.access.execute(Tools.toExpr(EBlock([
				Tools.moduleDeclsToExpr(targetClass.module.sharedDecls, {
					isScriptedClass: true,
					fieldFilter: f -> !f.access.contains(AStatic),
					classImpl: targetClass.impl
				})
			])));
		}

		interp.access.superInstance = this;
		interp.access.setVariable("this", this);

		if (args != null)
			if (variableExists('new'))
				Reflect.callMethod(this, getVariable('new'), args);
			else
				throw '${cl.toString()} does not have a constructor';
	}

	@:noCompletion public var __rulescript_type(get, never):TypeID;

	private function get___rulescript_type():TypeID
	{
		return CLASS;
	}

	public function getVariables():Map<String, Dynamic>
	{
		return interp.access.getVariables();
	}

	public function variableExists(name:String):Bool
	{
		return interp.access.variableExists(name) || cl.variableExists(name);
	}

	public function getVariable(name:String):Dynamic
	{
		if (interp.access.variableExists(name))
			return interp.access.getVariable(name);

		final active = RuleScriptedClassUtil.getClass(cl.toString()) ?? cl;
		return active.getVariable(name);
	}

	public function setVariable(name:String, value:Dynamic):Dynamic
	{
		final active = RuleScriptedClassUtil.getClass(cl.toString()) ?? cl;
		if (active.variableExists(name))
			return active.setVariable(name, value);
		return interp.access.setVariable(name, value);
	}

	public function hasScriptFunction(name:String):Bool
	{
		var current:Dynamic = cl;
		while (current != null)
		{
			if (current is ScriptedClass)
			{
				final sc:ScriptedClass = cast current;
				if (sc.hasScriptFunction(name)) return true;
				current = sc.superClass;
			}
			else
			{
				break;
			}
		}
		return false;
	}

	public function toString():String
	{
		return if (variableExists('toString'))
			getVariable('toString')();
		else
		{
			cl.toString();
		}
	}

	function get_variables():Map<String, Dynamic>
	{
		return interp.access.getVariables();
	}

	function set_variables(v:Map<String, Dynamic>):Map<String, Dynamic>
	{
		return interp.access.setVariables(v);
	}
}