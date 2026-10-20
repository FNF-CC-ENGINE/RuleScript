package rulescript.types;

@:build(rulescript.macro.TypedefMacro.build())
class Typedefs
{
	/**
	 * @param typePath	(example: `hello.world.A`, `hello.world.A.B`)
	 * @param type 
	 */
	public static dynamic function resolveTypedef(name:String):Dynamic
	{
		return typedefs[name];
	}

	inline public static function register(typePath:String, type:Dynamic)
	{
		return typedefs[typePath] = type;
	}

	inline public static function getAll():Map<String, Dynamic>
	{
		return typedefs;
	}
}