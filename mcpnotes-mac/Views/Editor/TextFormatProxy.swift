import AppKit

/// Routes formatting actions from the toolbar to the active NSTextView.
/// The coordinator registers its handlers once in makeNSView; toolbar buttons call them directly.
final class TextFormatProxy {
    private var wrapHandler: ((_ open: String, _ close: String) -> Void)?
    private var prefixHandler: ((_ prefix: String) -> Void)?
    private var codeHandler: (() -> Void)?
    private var insertTextHandler: ((_ text: String) -> Void)?

    func register(
        wrap: @escaping (_ open: String, _ close: String) -> Void,
        prefix: @escaping (_ prefix: String) -> Void,
        code: @escaping () -> Void,
        insert: @escaping (_ text: String) -> Void
    ) {
        wrapHandler = wrap
        prefixHandler = prefix
        codeHandler = code
        insertTextHandler = insert
    }

    func applyWrap(_ open: String, _ close: String) {
        wrapHandler?(open, close)
    }

    func applyPrefix(_ prefix: String) {
        prefixHandler?(prefix)
    }

    func applyCode() {
        codeHandler?()
    }

    func insertText(_ text: String) {
        insertTextHandler?(text)
    }
}
