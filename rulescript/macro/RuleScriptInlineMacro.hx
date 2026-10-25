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
        var count = 0;
        for (type in types) 
        {
            switch (type) 
            {
                case TClassDecl(c):
                    final cls = c.get();
                    if (cls.isPrivate || cls.isExtern || cls.isInterface) continue;
                    
                    final fields = generateInlineWrappers(cls.fields.get(), cls, false);
                    if (fields.length > 0) 
                    {
                        Context.defineType({
                            pos: Context.currentPos(),
                            pack: ['rulescript', '_internal', 'classes'].concat(cls.pack),
                            name: '${cls.name}_RuleScriptImpl_',
                            kind: TDClass(null, [], false, false, false),
                            fields: fields,
                            meta: [{name: ':keep', pos: Context.currentPos()}]
                        }, 'rulescript.macro.RuleScriptInlineMacro');
                        count++;
                    }

                case TAbstract(a):
                    final abs = a.get();
                    if (abs.impl == null || abs.isPrivate) continue;
                    
                    final implType = abs.impl.get();
                    if (implType.isExtern) continue;
                    
                    final fields = generateInlineWrappers(implType.statics.get(), abs, true);
                    if (fields.length > 0) 
                    {
                        Context.defineType({
                            pos: Context.currentPos(),
                            pack: ['rulescript', '_internal', 'abstracts'].concat(abs.pack),
                            name: '${abs.name}_RuleScriptImpl_',
                            kind: TDClass(null, [], false, false, false),
                            fields: fields,
                            meta: [{name: ':keep', pos: Context.currentPos()}]
                        }, 'rulescript.macro.RuleScriptInlineMacro');
                        count++;
                    }
                default:
            }
        }
    }

    static function generateInlineWrappers(fields:Array<ClassField>, typeDef:BaseType, isAbstract:Bool):Array<Field> 
    {
        final fullPath = typeDef.pack.concat([typeDef.name]).join('.');
        
        if (fullPath.indexOf('flixel.graphics.atlas.HashOrArray') != -1) return [];
        if (fullPath.startsWith('cpp')) return [];
        if (fullPath.startsWith('hl')) return [];

        final genFields:Array<Field> = [];
        for (field in fields) 
        {
            if (field.kind.match(FMethod(MethInline)) && field.isPublic) 
            {
                switch (field.type) 
                {
                    case TFun(args, ret):
                        if (isAbstract && (args.length == 0 || args[0].name != 'this')) continue;
                        
                        final isVoid = haxe.macro.TypeTools.toString(ret) == 'Void';
                        final actualArgs = isAbstract ? args.slice(1) : args;
                        final fieldArgs = [for (a in actualArgs) {name: a.name, type: null}];
                        final callArgs = [for (a in fieldArgs) a.name].join(', ');
                        
                        final typePath = TPath({
                            pack: typeDef.pack,
                            name: typeDef.module.split('.').pop(),
                            sub: typeDef.name,
                            params: [for (_ in typeDef.params) TPType((macro :Dynamic))]
                        });

                        final callStr = isVoid ? '__typedThis.${field.name}($callArgs)' : 'returnValue = __typedThis.${field.name}($callArgs)';
                        
                        genFields.push({
                            pos: Context.currentPos(),
                            name: field.name,
                            access: [APublic, AStatic],
                            kind: FFun({
                                args: [{name: '__this', type: macro:Dynamic}].concat(fieldArgs),
                                ret: macro:Dynamic,
                                expr: macro {
                                    var __typedThis = (__this : $typePath);
                                    var returnValue:Dynamic = null;
                                    @:privateAccess ${Context.parse(callStr, Context.currentPos())};
                                    return returnValue;
                                }
                            }),
                            meta: [{name: ':noCompletion', pos: Context.currentPos()}, {name: ':haxe.warning', params: [macro "-WAll"], pos: Context.currentPos()}]
                        });
                    default:
                }
            }
        }
        return genFields;
    }
    #end
}