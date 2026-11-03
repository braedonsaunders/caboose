/* caboose-msaa.exe: the controls of a Windows program running under Wine, for desktop MCP on
 * the agent seat. Wine has no bridge from Windows accessibility to AT-SPI, and its oleacc
 * proxies do not list a window's children, so this program runs inside the program's own
 * prefix and reads the window's Win32 child controls (class, text, state, place) and its menu
 * bar. It answers requests on stdin, one per line, tab-separated:
 *
 *   windows <TAB>                                  the titles of the visible top-level windows
 *   list <TAB> window title                        the window's controls
 *   press <TAB> window title <TAB> path            a control's default action, or a menu item
 *   set <TAB> window title <TAB> path <TAB> text   replace a field's text
 *
 * Each answer is one line of JSON: {"ok":true,"window":[x,y,w,h],"elements":[{"path","role",
 * "name","value","states":[...],"bounds":[x,y,w,h]}]} for list, {"ok":true} or
 * {"ok":false,"error":...} otherwise. A path is "w.N" (the window's Nth child control) or
 * "m.I.J..." (a menu item). Bounds are in Wine's screen pixels. Build:
 * x86_64-w64-mingw32-gcc -O2 -municode -o caboose-msaa.exe caboose-msaa.c -loleacc -loleaut32
 * -lole32 -luuid -luser32 */
#define COBJMACROS
#include <windows.h>
#include <oleacc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Defined here: mingw's import library resolves IID_IAccessible to the import thunk. */
static const GUID IID_IAccessible_ = { 0x618736e0, 0x3c3d, 0x11cf, { 0x81, 0x0c, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
#define IID_IAccessible IID_IAccessible_

#define MAX_NODES 3000
#define MAX_DEPTH 24

static void put_json_string(const wchar_t *text) {
    char utf8[4096];
    int n = text ? WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, sizeof utf8, NULL, NULL) : 0;
    putchar('"');
    for (int i = 0; n > 0 && utf8[i]; i++) {
        unsigned char c = (unsigned char)utf8[i];
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c == '\n') fputs("\\n", stdout);
        else if (c == '\r') fputs("\\r", stdout);
        else if (c == '\t') fputs("\\t", stdout);
        else if (c < 0x20) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

static void fail(const char *message) { printf("{\"ok\":false,\"error\":\"%s\"}\n", message); fflush(stdout); }

typedef struct { const wchar_t *title; HWND found; } Search;

static BOOL CALLBACK by_title(HWND hwnd, LPARAM lparam) {
    Search *search = (Search *)lparam;
    wchar_t text[512];
    if (!IsWindowVisible(hwnd)) return TRUE;
    GetWindowTextW(hwnd, text, 512);
    if (wcscmp(text, search->title) == 0) { search->found = hwnd; return FALSE; }
    return TRUE;
}

static BOOL CALLBACK print_title(HWND hwnd, LPARAM lparam) {
    int *first = (int *)lparam;
    wchar_t text[512];
    if (!IsWindowVisible(hwnd)) return TRUE;
    GetWindowTextW(hwnd, text, 512);
    if (!*text) return TRUE;
    if (!*first) putchar(',');
    put_json_string(text);
    *first = 0;
    return TRUE;
}

static HWND window_titled(const wchar_t *title) {
    Search search = { title, NULL };
    EnumWindows(by_title, (LPARAM)&search);
    return search.found;
}

/* A node is an object and a child id (CHILDID_SELF for the object itself). */
typedef struct { IAccessible *object; long child; } Node;

static int children(Node node, VARIANT **out, long *count) {
    *out = NULL; *count = 0;
    if (node.child != CHILDID_SELF) return 0;
    long n = 0;
    if (FAILED(IAccessible_get_accChildCount(node.object, &n)) || n <= 0) return 0;
    if (n > 1000) n = 1000;
    VARIANT *list = calloc(n, sizeof(VARIANT));
    long got = 0;
    if (FAILED(AccessibleChildren(node.object, 0, n, list, &got))) { free(list); return 0; }
    *out = list; *count = got;
    return 1;
}

/* The node at child index `index` of `node`; the caller releases a returned object. */
static int child_at(Node node, long index, Node *out) {
    VARIANT *list; long count;
    if (!children(node, &list, &count) || index < 0 || index >= count) { if (list) free(list); return 0; }
    int ok = 0;
    for (long i = 0; i < count; i++) {
        if (i == index) {
            if (list[i].vt == VT_DISPATCH && list[i].pdispVal) {
                IAccessible *object = NULL;
                if (SUCCEEDED(IDispatch_QueryInterface(list[i].pdispVal, &IID_IAccessible, (void **)&object))) {
                    out->object = object; out->child = CHILDID_SELF; ok = 1;
                }
            } else if (list[i].vt == VT_I4) {
                IAccessible_AddRef(node.object);
                out->object = node.object; out->child = list[i].lVal; ok = 1;
            }
        }
        VariantClear(&list[i]);
    }
    free(list);
    return ok;
}

static void emit(Node node, const char *path, int *first) {
    VARIANT self; VariantInit(&self); self.vt = VT_I4; self.lVal = node.child;
    VARIANT role, state;
    BSTR name = NULL, value = NULL, action = NULL;
    long x = 0, y = 0, w = 0, h = 0;
    VariantInit(&role); VariantInit(&state);
    IAccessible_get_accRole(node.object, self, &role);
    IAccessible_get_accState(node.object, self, &state);
    long flags = state.vt == VT_I4 ? state.lVal : 0;
    if (flags & (STATE_SYSTEM_INVISIBLE | STATE_SYSTEM_OFFSCREEN)) return;
    IAccessible_get_accName(node.object, self, &name);
    IAccessible_get_accValue(node.object, self, &value);
    IAccessible_get_accDefaultAction(node.object, self, &action);
    IAccessible_accLocation(node.object, &x, &y, &w, &h, self);
    wchar_t role_text[128] = L"";
    if (role.vt == VT_I4) GetRoleTextW(role.lVal, role_text, 128);
    printf("%s{\"path\":\"%s\",\"role\":", *first ? "" : ",", path);
    put_json_string(role_text);
    fputs(",\"name\":", stdout); put_json_string(name ? name : L"");
    if (value && *value) { fputs(",\"value\":", stdout); put_json_string(value); }
    if (action && *action) { fputs(",\"action\":", stdout); put_json_string(action); }
    printf(",\"bounds\":[%ld,%ld,%ld,%ld],\"states\":[", x, y, w, h);
    static const struct { long flag; const char *label; } labels[] = {
        { STATE_SYSTEM_UNAVAILABLE, "disabled" }, { STATE_SYSTEM_FOCUSED, "focused" }, { STATE_SYSTEM_CHECKED, "checked" },
        { STATE_SYSTEM_SELECTED, "selected" }, { STATE_SYSTEM_READONLY, "read-only" }, { STATE_SYSTEM_PRESSED, "pressed" },
        { STATE_SYSTEM_EXPANDED, "expanded" }, { STATE_SYSTEM_COLLAPSED, "collapsed" }, { STATE_SYSTEM_FOCUSABLE, "focusable" },
        { STATE_SYSTEM_PROTECTED, "protected" } };
    int any = 0;
    for (size_t i = 0; i < sizeof labels / sizeof *labels; i++)
        if (flags & labels[i].flag) { printf("%s\"%s\"", any ? "," : "", labels[i].label); any = 1; }
    fputs("]}", stdout);
    *first = 0;
    SysFreeString(name); SysFreeString(value); SysFreeString(action);
    VariantClear(&role); VariantClear(&state);
}

static int visited;

static void walk(Node node, const char *path, int depth, int *first) {
    if (visited++ > MAX_NODES) return;
    if (*path) emit(node, path, first);
    if (depth >= MAX_DEPTH || node.child != CHILDID_SELF) return;
    VARIANT *list; long count;
    if (!children(node, &list, &count)) return;
    for (long i = 0; i < count; i++) {
        char sub[512];
        snprintf(sub, sizeof sub, "%s%s%ld", path, *path ? "." : "", i);
        Node next = { NULL, CHILDID_SELF };
        if (list[i].vt == VT_DISPATCH && list[i].pdispVal) {
            if (SUCCEEDED(IDispatch_QueryInterface(list[i].pdispVal, &IID_IAccessible, (void **)&next.object))) {
                walk(next, sub, depth + 1, first);
                IAccessible_Release(next.object);
            }
        } else if (list[i].vt == VT_I4) {
            next.object = node.object; next.child = list[i].lVal;
            walk(next, sub, depth + 1, first);
        }
        VariantClear(&list[i]);
    }
    free(list);
}

static const char *root_error;

static int root_of(const wchar_t *title, Node *out) {
    HWND hwnd = window_titled(title);
    root_error = "no window of that title";
    if (!hwnd) return 0;
    IAccessible *object = NULL;
    HRESULT result = AccessibleObjectFromWindow(hwnd, OBJID_WINDOW, &IID_IAccessible, (void **)&object);
    /* A program that does not answer WM_GETOBJECT itself: oleacc's standard proxy, which reads
     * its controls through window messages. */
    if (FAILED(result) || !object) result = CreateStdAccessibleObject(hwnd, OBJID_WINDOW, &IID_IAccessible, (void **)&object);
    if (FAILED(result) || !object) { static char error[96]; snprintf(error, sizeof error, "the window has no accessible object (0x%08lx)", (unsigned long)result); root_error = error; return 0; }
    root_error = "the window has no accessible object";
    if (FAILED(result) || !object) return 0;
    out->object = object; out->child = CHILDID_SELF;
    return 1;
}

static int resolve(const wchar_t *title, const char *path, Node *out) {
    Node node;
    if (!root_of(title, &node)) return 0;
    const char *at = path;
    while (*at) {
        long index = strtol(at, (char **)&at, 10);
        Node next;
        int ok = child_at(node, index, &next);
        IAccessible_Release(node.object);
        if (!ok) return 0;
        node = next;
        if (*at == '.') at++;
    }
    *out = node;
    return 1;
}

/* Win32 controls: the window's menu bar and its child windows (Wine's oleacc proxies do not
 * list a window's children), each described through its standard accessible object. */
typedef struct { HWND list[512]; int count; } Children;

static BOOL CALLBACK collect_child(HWND hwnd, LPARAM lparam) {
    Children *children = (Children *)lparam;
    if (children->count < 512 && IsWindowVisible(hwnd)) children->list[children->count++] = hwnd;
    return TRUE;
}

static void emit_menu(HMENU menu, const char *path, int depth, int *first) {
    int count = GetMenuItemCount(menu);
    for (int i = 0; i < count && i < 64; i++) {
        wchar_t text[256] = L"";
        MENUITEMINFOW info = { sizeof info };
        info.fMask = MIIM_STRING | MIIM_SUBMENU | MIIM_STATE | MIIM_FTYPE | MIIM_ID;
        info.dwTypeData = text; info.cch = 255;
        if (!GetMenuItemInfoW(menu, i, TRUE, &info) || (info.fType & MFT_SEPARATOR) || !*text) continue;
        /* The accelerator marker and the shortcut after a tab are not part of the name. */
        wchar_t name[256]; int n = 0;
        for (wchar_t *c = text; *c && *c != L'\t' && n < 255; c++) if (*c != L'&') name[n++] = *c;
        name[n] = 0;
        char sub[64];
        snprintf(sub, sizeof sub, "%s.%d", path, i);
        printf("%s{\"path\":\"%s\",\"role\":\"%s\",\"name\":", *first ? "" : ",", sub, info.hSubMenu ? "menu" : "menu item");
        put_json_string(name);
        printf(",\"states\":[%s%s]}", (info.fState & MFS_DISABLED) ? "\"disabled\"" : "",
               (info.fState & MFS_CHECKED) ? ((info.fState & MFS_DISABLED) ? ",\"checked\"" : "\"checked\"") : "");
        *first = 0;
        if (info.hSubMenu && depth < 3) emit_menu(info.hSubMenu, sub, depth + 1, first);
    }
}

/* A control's role from its window class, for the classes the standard proxy only calls
 * "client". */
/* A window's text, and setting it. Some controls (Scintilla) take and give WM_SETTEXT and
 * WM_GETTEXT text as bytes in their own encoding (UTF-8) even in a Unicode window: whichever
 * of the two forms reads back the longer text is the control's. */
static void get_text(HWND hwnd, wchar_t *out, int size) {
    wchar_t wide[4096] = L"";
    char bytes[8192] = "";
    SendMessageTimeoutW(hwnd, WM_GETTEXT, 4096, (LPARAM)wide, SMTO_ABORTIFHUNG, 200, NULL);
    SendMessageTimeoutA(hwnd, WM_GETTEXT, sizeof bytes, (LPARAM)bytes, SMTO_ABORTIFHUNG, 200, NULL);
    wchar_t narrow[4096] = L"";
    MultiByteToWideChar(CP_UTF8, 0, bytes, -1, narrow, 4096);
    const wchar_t *best = wcslen(narrow) > wcslen(wide) ? narrow : wide;
    wcsncpy(out, best, size - 1);
    out[size - 1] = 0;
}

static BOOL set_text(HWND hwnd, const wchar_t *text) {
    SendMessageW(hwnd, WM_SETTEXT, 0, (LPARAM)text);
    wchar_t now[4096];
    get_text(hwnd, now, 4096);
    if (wcscmp(now, text) == 0) return TRUE;
    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    char *bytes = calloc(n + 1, 1);
    WideCharToMultiByte(CP_UTF8, 0, text, -1, bytes, n, NULL, NULL);
    SendMessageA(hwnd, WM_SETTEXT, 0, (LPARAM)bytes);
    free(bytes);
    get_text(hwnd, now, 4096);
    return wcscmp(now, text) == 0;
}

static const char *class_role(HWND hwnd, int *editable) {
    wchar_t cls[64] = L"";
    GetClassNameW(hwnd, cls, 64);
    LONG style = GetWindowLongW(hwnd, GWL_STYLE);
    *editable = 0;
    if (!_wcsicmp(cls, L"Edit") || wcsstr(cls, L"RichEdit") || wcsstr(cls, L"RICHEDIT") || !_wcsicmp(cls, L"Scintilla")) {
        *editable = !(style & ES_READONLY);
        return "text";
    }
    if (!_wcsicmp(cls, L"Button")) {
        LONG type = style & BS_TYPEMASK;
        if (type == BS_CHECKBOX || type == BS_AUTOCHECKBOX || type == BS_3STATE || type == BS_AUTO3STATE) return "check box";
        if (type == BS_RADIOBUTTON || type == BS_AUTORADIOBUTTON) return "radio button";
        if (type == BS_GROUPBOX) return "panel";
        return "push button";
    }
    if (!_wcsicmp(cls, L"Static")) return "label";
    if (!_wcsicmp(cls, L"ComboBox") || !_wcsicmp(cls, L"ComboBoxEx32")) return "combo box";
    if (!_wcsicmp(cls, L"ListBox") || !_wcsicmp(cls, L"SysListView32")) return "list";
    if (!_wcsicmp(cls, L"SysTreeView32")) return "tree";
    if (!_wcsicmp(cls, L"SysTabControl32")) return "page tab list";
    if (!_wcsicmp(cls, L"ToolbarWindow32")) return "tool bar";
    if (!_wcsicmp(cls, L"msctls_statusbar32")) return "status bar";
    return NULL;
}

static void emit_control(HWND hwnd, int index, int *first) {
    int editable = 0;
    const char *role = class_role(hwnd, &editable);
    wchar_t name[256] = L"", value[2048] = L"";
    if (editable || (role && !strcmp(role, "text"))) get_text(hwnd, value, 2048);
    else GetWindowTextW(hwnd, name, 256);
    RECT box; GetWindowRect(hwnd, &box);
    LONG style = GetWindowLongW(hwnd, GWL_STYLE);
    printf("%s{\"path\":\"w.%d\",\"role\":\"%s\",\"name\":", *first ? "" : ",", index, role ? role : "panel");
    put_json_string(name);
    if (*value) { fputs(",\"value\":", stdout); put_json_string(value); }
    printf(",\"bounds\":[%ld,%ld,%ld,%ld],\"states\":[", box.left, box.top, box.right - box.left, box.bottom - box.top);
    int any = 0;
    if (style & WS_DISABLED) { fputs("\"disabled\"", stdout); any = 1; }
    if (GetFocus() == hwnd) { printf("%s\"focused\"", any ? "," : ""); any = 1; }
    if (editable) { printf("%s\"editable\"", any ? "," : ""); any = 1; }
    if (role && (!strcmp(role, "check box") || !strcmp(role, "radio button")) && SendMessageW(hwnd, BM_GETCHECK, 0, 0) == BST_CHECKED)
        printf("%s\"checked\"", any ? "," : "");
    fputs("]}", stdout);
    *first = 0;
}

static void list_win32(HWND top, int *first) {
    HMENU menu = GetMenu(top);
    if (menu) emit_menu(menu, "m", 0, first);
    Children children = { .count = 0 };
    EnumChildWindows(top, collect_child, (LPARAM)&children);
    for (int i = 0; i < children.count; i++) emit_control(children.list[i], i, first);
}

static HWND control_at(HWND top, const char *path) {
    Children children = { .count = 0 };
    EnumChildWindows(top, collect_child, (LPARAM)&children);
    int index = atoi(path + 2);
    return index >= 0 && index < children.count ? children.list[index] : NULL;
}

static UINT menu_command(HWND top, const char *path, int *found) {
    HMENU menu = GetMenu(top);
    const char *at = path + 1;
    *found = 0;
    while (menu && *at == '.') {
        int index = strtol(at + 1, (char **)&at, 10);
        MENUITEMINFOW info = { sizeof info };
        info.fMask = MIIM_SUBMENU | MIIM_ID;
        if (!GetMenuItemInfoW(menu, index, TRUE, &info)) return 0;
        if (*at != '.') { *found = !info.hSubMenu; return info.wID; }
        menu = info.hSubMenu;
    }
    return 0;
}

static wchar_t *widen(const char *text) {
    int n = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    wchar_t *wide = calloc(n + 1, sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, n);
    return wide;
}

int wmain(void) {
    CoInitialize(NULL);
    char line[65536];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        char *fields[4] = { 0 };
        int n = 0;
        for (char *part = line; part && n < 4; n++) {
            fields[n] = part;
            char *tab = n < 3 ? strchr(part, '\t') : NULL;
            if (tab) { *tab = 0; part = tab + 1; } else part = NULL;
        }
        if (n < 2 && strcmp(fields[0], "windows") != 0) { fail("a request is op TAB title [TAB path [TAB text]]"); continue; }
        wchar_t *title = widen(fields[1]);
        if (strcmp(fields[0], "windows") == 0) {
            int first = 1;
            fputs("{\"ok\":true,\"windows\":[", stdout);
            EnumWindows(print_title, (LPARAM)&first);
            fputs("]}\n", stdout); fflush(stdout);
        } else if (strcmp(fields[0], "list") == 0) {
            Node root;
            if (!root_of(title, &root)) { fail(root_error); free(title); continue; }
            int first = 1;
            visited = 0;
            RECT box; GetWindowRect(window_titled(title), &box);
            printf("{\"ok\":true,\"window\":[%ld,%ld,%ld,%ld],\"elements\":[", box.left, box.top, box.right - box.left, box.bottom - box.top);
            list_win32(window_titled(title), &first);
            fputs("]}\n", stdout); fflush(stdout);
            IAccessible_Release(root.object);
        } else if ((strcmp(fields[0], "press") == 0 || strcmp(fields[0], "set") == 0) && n >= 3 && (fields[2][0] == 'm' || fields[2][0] == 'w')) {
            HWND top = window_titled(title);
            if (!top) { fail("no window of that title"); free(title); continue; }
            int ok = 0;
            if (fields[2][0] == 'm' && fields[0][0] == 'p') {
                int leaf; UINT id = menu_command(top, fields[2], &leaf);
                if (leaf) ok = PostMessageW(top, WM_COMMAND, MAKEWPARAM(id, 0), 0);
                else { fail("a menu opens by pressing one of its items"); free(title); continue; }
            } else if (fields[2][0] == 'w') {
                HWND control = control_at(top, fields[2]);
                if (!control) { fail("element not found"); free(title); continue; }
                if (fields[0][0] == 's') {
                    wchar_t *text = widen(fields[3] ? fields[3] : "");
                    ok = set_text(control, text);
                    free(text);
                } else {
                    IAccessible *object = NULL;
                    if (SUCCEEDED(CreateStdAccessibleObject(control, OBJID_CLIENT, &IID_IAccessible, (void **)&object)) && object) {
                        VARIANT self; VariantInit(&self); self.vt = VT_I4; self.lVal = CHILDID_SELF;
                        ok = SUCCEEDED(IAccessible_accDoDefaultAction(object, self));
                        IAccessible_Release(object);
                    }
                    if (!ok) { SendMessageW(control, BM_CLICK, 0, 0); ok = 1; }
                }
            }
            if (ok) { puts("{\"ok\":true}"); fflush(stdout); } else fail("the control refused the action");
        } else if ((strcmp(fields[0], "press") == 0 || strcmp(fields[0], "set") == 0) && n >= 3) {
            Node node;
            if (!resolve(title, fields[2], &node)) { fail("element not found"); free(title); continue; }
            VARIANT self; VariantInit(&self); self.vt = VT_I4; self.lVal = node.child;
            HRESULT result;
            if (fields[0][0] == 'p') result = IAccessible_accDoDefaultAction(node.object, self);
            else {
                wchar_t *text = widen(fields[3] ? fields[3] : "");
                HWND hwnd = NULL;
                /* An edit control takes its text by message; anything else through accValue. */
                if (node.child == CHILDID_SELF && SUCCEEDED(WindowFromAccessibleObject(node.object, &hwnd)) && hwnd) {
                    wchar_t cls[64]; GetClassNameW(hwnd, cls, 64);
                    result = _wcsicmp(cls, L"Edit") == 0 || wcsstr(cls, L"Edit") ? (SendMessageW(hwnd, WM_SETTEXT, 0, (LPARAM)text) ? S_OK : E_FAIL) : E_FAIL;
                } else result = E_FAIL;
                if (FAILED(result)) { BSTR value = SysAllocString(text); result = IAccessible_put_accValue(node.object, self, value); SysFreeString(value); }
                free(text);
            }
            IAccessible_Release(node.object);
            if (SUCCEEDED(result)) { puts("{\"ok\":true}"); fflush(stdout); } else fail("the control refused the action");
        } else fail("unknown request");
        free(title);
    }
    CoUninitialize();
    return 0;
}
