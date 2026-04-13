#if __has_include(<mpv/client.h>)
#include <mpv/client.h>
#include <mpv/render.h>
#elif __has_include("/opt/homebrew/opt/mpv/include/mpv/client.h")
#include "/opt/homebrew/opt/mpv/include/mpv/client.h"
#include "/opt/homebrew/opt/mpv/include/mpv/render.h"
#elif __has_include("/usr/local/opt/mpv/include/mpv/client.h")
#include "/usr/local/opt/mpv/include/mpv/client.h"
#include "/usr/local/opt/mpv/include/mpv/render.h"
#else
#error "libmpv headers not found. Install mpv with Homebrew."
#endif
