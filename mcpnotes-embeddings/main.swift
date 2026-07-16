import Foundation

let delegate = ServiceDelegate()

let serviceListener = NSXPCListener.service()
serviceListener.delegate = delegate
serviceListener.resume()

let machListener = NSXPCListener(machServiceName: "group.mcp-notes.embeddings")
machListener.delegate = delegate
machListener.resume()

RunLoop.main.run()
