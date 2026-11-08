/* The GNUstep-base macros Mail2's sources use, for building its core with Apple's Foundation on the host
 * (tests/run_host_tests.sh). Not used in the real build. */
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#ifndef ASSIGN
#define ASSIGN(var, val) do { id _n = (id)(val); [_n retain]; [(id)(var) release]; (var) = _n; } while (0)
#endif
#ifndef DESTROY
#define DESTROY(var) do { [(id)(var) release]; (var) = nil; } while (0)
#endif
#endif
