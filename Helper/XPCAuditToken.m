// OpenNTFS - ObjC bridge for NSXPCConnection peer audit token.
// SPDX-License-Identifier: GPL-2.0-or-later

#import "XPCAuditToken.h"

// Present at runtime on Apple platforms; not always declared in the public SDK.
@interface NSXPCConnection (OpenNTFSAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

audit_token_t OpenNTFSConnectionAuditToken(NSXPCConnection *connection) {
    return connection.auditToken;
}

uid_t OpenNTFSConnectionEUID(NSXPCConnection *connection) {
    return audit_token_to_euid(connection.auditToken);
}

gid_t OpenNTFSConnectionEGID(NSXPCConnection *connection) {
    return audit_token_to_egid(connection.auditToken);
}
