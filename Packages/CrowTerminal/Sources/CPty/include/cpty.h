#ifndef CROW_CPTY_H
#define CROW_CPTY_H

/*
 * Bridges `openpty(3)` into Swift on Linux.
 *
 * On Apple platforms `openpty` is declared by the `Darwin` module, so this
 * shim is a Linux-only dependency of `CrowTerminal` (see Package.swift). glibc
 * declares `openpty` in <pty.h> and implements it in libutil — neither is
 * surfaced by Swift's `Glibc` module, so `PTYProcess` imports `CPty` and links
 * `-lutil` on Linux to resolve the symbol. The header is empty elsewhere.
 */
#if defined(__linux__)
#include <pty.h>
#endif

#endif /* CROW_CPTY_H */
