/*
 * DOSBox-X-Print launcher
 *
 * This is the bundle's CFBundleExecutable. It keeps every file DOSBox-X writes
 * (the saved configuration and the temporary print files) outside the signed
 * app bundle, so changing settings or printing never invalidates the code
 * signature.
 *
 *   1. Creates ~/Library/Application Support/DOSBox-X-Print/ if needed.
 *   2. On first launch, copies the bundle's default Resources/dosbox-x.conf
 *      there.
 *   3. Prepends Contents/Resources to PATH, so the print commands in the
 *      config ("textprint.sh temp.prn" etc.) find the bundled scripts no
 *      matter where the app lives.
 *   4. Replaces itself with the real emulator, Contents/MacOS/dosbox-x-bin,
 *      passing "-conf <that file>" unless the caller chose a config itself.
 *
 * Because the config has "working directory option = config", DOSBox-X then
 * runs with the Application Support folder as its working directory, and "Save" in the
 * configuration dialog writes back to the same file.
 */

#include <copyfile.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CONFIG_SUBDIR "Library/Application Support/DOSBox-X-Print"
#define CONFIG_NAME "dosbox-x.conf"
#define REAL_BINARY "dosbox-x-bin"

static void fail(const char *what, const char *path) {
    fprintf(stderr, "dosbox-x-print: %s %s: %s\n", what, path ? path : "", strerror(errno));
}

/* mkdir -p */
static int make_dirs(const char *path) {
    char tmp[PATH_MAX];
    if (strlcpy(tmp, path, sizeof tmp) >= sizeof tmp) { errno = ENAMETOOLONG; return -1; }
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static int has_config_option(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        while (*a == '-') a++; /* DOSBox-X accepts -opt and --opt */
        if (!strcmp(a, "conf") || !strcmp(a, "defaultconf") || !strcmp(a, "userconf"))
            return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    /* Contents/MacOS directory of this bundle */
    char exe[PATH_MAX], macos_dir[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, macos_dir) == NULL) {
        fail("cannot resolve executable path", NULL);
        return 1;
    }
    char *slash = strrchr(macos_dir, '/');
    if (!slash) return 1;
    *slash = '\0';

    char real_bin[PATH_MAX], resources[PATH_MAX];
    snprintf(real_bin, sizeof real_bin, "%s/%s", macos_dir, REAL_BINARY);
    snprintf(resources, sizeof resources, "%s/../Resources", macos_dir);
    char resolved[PATH_MAX];
    if (realpath(resources, resolved)) strlcpy(resources, resolved, sizeof resources);

    /* Make the bundled print scripts reachable by name */
    const char *old_path = getenv("PATH");
    if (!old_path || !*old_path) old_path = "/usr/bin:/bin:/usr/sbin:/sbin";
    size_t path_len = strlen(resources) + strlen(old_path) + 2;
    char *new_path = malloc(path_len);
    if (new_path) {
        snprintf(new_path, path_len, "%s:%s", resources, old_path);
        setenv("PATH", new_path, 1);
        free(new_path);
    }
    setenv("DOSBOX_X_PRINT_RESOURCES", resources, 1);

    /* Arguments for the real binary. argv[0] must be the full path inside
       Contents/MacOS/, which DOSBox-X uses to locate Contents/Resources. */
    char **args = calloc((size_t)argc + 3, sizeof *args);
    if (!args) return 1;
    int n = 0;
    args[n++] = real_bin;

    char conf[PATH_MAX];
    if (!has_config_option(argc, argv)) {
        const char *home = getenv("HOME");
        if (!home || !*home) {
            struct passwd *pw = getpwuid(getuid());
            home = pw ? pw->pw_dir : NULL;
        }
        if (home) {
            char dir[PATH_MAX], def[PATH_MAX];
            snprintf(dir, sizeof dir, "%s/%s", home, CONFIG_SUBDIR);
            snprintf(conf, sizeof conf, "%s/%s", dir, CONFIG_NAME);
            snprintf(def, sizeof def, "%s/%s", resources, CONFIG_NAME);

            struct stat st;
            int have_conf = stat(conf, &st) == 0;
            if (!have_conf) {
                if (make_dirs(dir) != 0)
                    fail("cannot create", dir);
                else if (copyfile(def, conf, NULL, COPYFILE_DATA | COPYFILE_EXCL) != 0)
                    fail("cannot copy default config to", conf);
                else
                    have_conf = 1;
            }
            /* If the user copy can't be created, still start with the
               bundled defaults rather than DOSBox-X's generic ones. */
            if (!have_conf) strlcpy(conf, def, sizeof conf);
            args[n++] = "-conf";
            args[n++] = conf;
        }
    }
    for (int i = 1; i < argc; i++) args[n++] = argv[i];
    args[n] = NULL;

    execv(real_bin, args);
    fail("cannot run", real_bin);
    return 1;
}
