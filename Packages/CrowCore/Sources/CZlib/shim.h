// zlib, for gzip-compressing session transcripts before upload (CROW-1394).
// Foundation has no gzip on Linux; macOS ships libz in the SDK and the
// swift:6.1 image ships zlib1g-dev, so both lanes link the system library.
#include <zlib.h>
