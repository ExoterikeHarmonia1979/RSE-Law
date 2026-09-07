// Manual Jest mock for '@microsoft/sp-http'.
//
// The real package cannot be require()'d outside a live SPFx/browser host: its
// module-load chain pulls in @microsoft/sp-core-library, which touches `window`
// at import time (ServiceKey generation) and unconditionally requires
// '@msinternal/ecs-flight', a Microsoft-internal package that is not published
// and does not exist in this (or any external) node_modules tree. That makes the
// real module unrequireable under plain Jest regardless of test environment.
//
// BlobBrowseService.ts only needs the HttpClient export for its static
// `configurations.v1` marker (an opaque token passed straight through to the
// fake HttpClient supplied by the tests) and as a type for its constructor
// parameter. Both are satisfied by this stub; no test exercises the real
// network stack, since BlobBrowseService.test.ts always injects a fake client.
class HttpClient {
  static configurations = { v1: 'HttpClient-configurations-v1' };
}

module.exports = { HttpClient };
