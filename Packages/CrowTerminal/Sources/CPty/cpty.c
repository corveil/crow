// See include/cpty.h. This translation unit exists so CPty is a normal clang
// target (not header-only); the openpty(3) declaration it surfaces on Linux
// comes from <pty.h> via the umbrella header.
#include "cpty.h"
