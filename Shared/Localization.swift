// OpenNTFS - locale picker shared by app sources and offline tests.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Moved verbatim from App/OpenNTFSApp.swift so the extracted maintenance
// report layer (App/Mounter.swift) and offline orchestration tests compile
// against a single definition — no duplicate implementations.

import Foundation

/// Picks the Chinese or the English text depending on the system language.
func L(_ en: String, _ zh: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? zh : en
}
