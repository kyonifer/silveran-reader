import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct PublicInitMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        PublicInitMacro.self
    ]
}
