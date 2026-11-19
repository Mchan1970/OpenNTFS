// OpenNTFS - FSKit module entry point.
// SPDX-License-Identifier: GPL-2.0-or-later

import ExtensionFoundation
import FSKit
import Foundation

@main
struct NTFSExtension: UnaryFileSystemExtension {
    let fileSystem = NTFSFileSystem()
}
