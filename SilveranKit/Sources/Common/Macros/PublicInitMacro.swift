import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct PublicInitMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf decl: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let structDecl = decl.as(StructDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@PublicInit can only be applied to structs")
        }

        let storedProps = structDecl.memberBlock.members.compactMap {
            member -> VariableDeclSyntax? in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                varDecl.bindings.first?.accessorBlock == nil
            else { return nil }
            return varDecl
        }

        let parameters = storedProps.compactMap { prop -> String? in
            guard
                let name = prop.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier
                    .text
            else { return nil }
            let type = prop.bindings.first?.typeAnnotation?.type.trimmedDescription ?? "Any"
            let defaultValue = prop.bindings.first?.initializer?.value.trimmedDescription
            if let defaultValue, !defaultValue.isEmpty {
                return "\(name): \(type) = \(defaultValue)"
            }
            return "\(name): \(type)"
        }.joined(separator: ", ")

        let assignments = storedProps.compactMap { prop -> String? in
            guard
                let name = prop.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier
                    .text
            else { return nil }
            return "self.\(name) = \(name)"
        }.joined(separator: "\n        ")

        let initDecl: DeclSyntax =
            """
            public init(\(raw: parameters)) {
                \(raw: assignments)
            }
            """

        return [initDecl]
    }
}
