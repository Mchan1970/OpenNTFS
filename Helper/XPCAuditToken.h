// OpenNTFS - ObjC bridge for NSXPCConnection peer audit token.
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

/// Copies the peer audit token from an XPC connection (runtime API).
audit_token_t OpenNTFSConnectionAuditToken(NSXPCConnection *connection);

uid_t OpenNTFSConnectionEUID(NSXPCConnection *connection);
gid_t OpenNTFSConnectionEGID(NSXPCConnection *connection);

NS_ASSUME_NONNULL_END
