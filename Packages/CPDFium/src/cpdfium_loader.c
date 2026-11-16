#include "cpdfium.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/dyld.h>

static void* g_handle = NULL;
static char g_loaded_path[1024] = {0};

// Function pointer typedefs
typedef void (*fn_InitLibrary)(void);
typedef void (*fn_DestroyLibrary)(void);
typedef unsigned long (*fn_GetLastError)(void);
typedef FPDF_DOCUMENT (*fn_LoadDocument)(FPDF_BYTESTRING, FPDF_BYTESTRING);
typedef FPDF_DOCUMENT (*fn_CreateNewDocument)(void);
typedef void (*fn_CloseDocument)(FPDF_DOCUMENT);
typedef int (*fn_GetPageCount)(FPDF_DOCUMENT);
typedef FPDF_BOOL (*fn_CopyViewerPreferences)(FPDF_DOCUMENT, FPDF_DOCUMENT);
typedef FPDF_PAGE (*fn_LoadPage)(FPDF_DOCUMENT, int);
typedef void (*fn_ClosePage)(FPDF_PAGE);
typedef FPDF_PAGE (*fn_PageNew)(FPDF_DOCUMENT, int, double, double);
typedef void (*fn_DeletePage)(FPDF_DOCUMENT, int);
typedef float (*fn_GetPageWidthF)(FPDF_PAGE);
typedef float (*fn_GetPageHeightF)(FPDF_PAGE);
typedef FPDF_BOOL (*fn_PageGetMediaBox)(FPDF_PAGE, float*, float*, float*, float*);
typedef FPDF_BOOL (*fn_PageSetMediaBox)(FPDF_PAGE, float, float, float, float);
typedef FPDF_BOOL (*fn_PageGenerateContent)(FPDF_PAGE);

typedef FPDF_TEXTPAGE (*fn_TextLoadPage)(FPDF_PAGE);
typedef void (*fn_TextClosePage)(FPDF_TEXTPAGE);
typedef int (*fn_TextCountChars)(FPDF_TEXTPAGE);
typedef unsigned int (*fn_TextGetUnicode)(FPDF_TEXTPAGE, int);
typedef FPDF_PAGEOBJECT (*fn_TextGetTextObject)(FPDF_TEXTPAGE, int);
typedef int (*fn_TextIsGenerated)(FPDF_TEXTPAGE, int);
typedef FPDF_BOOL (*fn_TextGetCharBox)(FPDF_TEXTPAGE, int, double*, double*, double*, double*);
typedef FPDF_BOOL (*fn_TextGetLooseCharBox)(FPDF_TEXTPAGE, int, FS_RECTF*);
typedef float (*fn_TextGetCharAngle)(FPDF_TEXTPAGE, int);
typedef double (*fn_TextGetFontSize)(FPDF_TEXTPAGE, int);
typedef unsigned long (*fn_TextGetFontInfo)(FPDF_TEXTPAGE, int, void*, unsigned long, int*);
typedef FPDF_BOOL (*fn_TextGetFillColor)(FPDF_TEXTPAGE, int, unsigned int*, unsigned int*, unsigned int*, unsigned int*);
typedef FPDF_FONT (*fn_TextObjGetFont)(FPDF_PAGEOBJECT);

typedef int (*fn_PageCountObjects)(FPDF_PAGE);
typedef FPDF_PAGEOBJECT (*fn_PageGetObject)(FPDF_PAGE, int);
typedef FPDF_BOOL (*fn_PageRemoveObject)(FPDF_PAGE, FPDF_PAGEOBJECT);
typedef void (*fn_PageObjDestroy)(FPDF_PAGEOBJECT);
typedef int (*fn_PageObjGetType)(FPDF_PAGEOBJECT);
typedef FPDF_BOOL (*fn_PageObjGetBounds)(FPDF_PAGEOBJECT, float*, float*, float*, float*);
typedef void (*fn_PageObjTransform)(FPDF_PAGEOBJECT, double, double, double, double, double, double);
typedef FPDF_BOOL (*fn_PageObjGetFillColor)(FPDF_PAGEOBJECT, unsigned int*, unsigned int*, unsigned int*, unsigned int*);
typedef FPDF_BOOL (*fn_PageObjSetFillColor)(FPDF_PAGEOBJECT, unsigned int, unsigned int, unsigned int, unsigned int);
typedef unsigned long (*fn_TextObjGetText)(FPDF_PAGEOBJECT, FPDF_TEXTPAGE, FPDF_WCHAR*, unsigned long);
typedef FPDF_BOOL (*fn_TextObjGetFontSize)(FPDF_PAGEOBJECT, float*);

typedef FPDF_FONT (*fn_TextLoadFont)(FPDF_DOCUMENT, const uint8_t*, uint32_t, int, FPDF_BOOL);
typedef FPDF_FONT (*fn_TextLoadStandardFont)(FPDF_DOCUMENT, FPDF_BYTESTRING);
typedef void (*fn_FontClose)(FPDF_FONT);
typedef FPDF_PAGEOBJECT (*fn_PageObjCreateTextObj)(FPDF_DOCUMENT, FPDF_FONT, float);
typedef FPDF_BOOL (*fn_TextSetText)(FPDF_PAGEOBJECT, const FPDF_WCHAR*);
typedef void (*fn_PageInsertObject)(FPDF_PAGE, FPDF_PAGEOBJECT);

typedef FPDF_PAGEOBJECT (*fn_PageObjCreateNewRect)(float, float, float, float);
typedef FPDF_BOOL (*fn_PathSetDrawMode)(FPDF_PAGEOBJECT, int, FPDF_BOOL);

typedef FPDF_BOOL (*fn_ImportPages)(FPDF_DOCUMENT, FPDF_DOCUMENT, FPDF_BYTESTRING, int);
typedef FPDF_DOCUMENT (*fn_ImportNPagesToOne)(FPDF_DOCUMENT, float, float, size_t, size_t);
typedef FPDF_BOOL (*fn_SaveAsCopy)(FPDF_DOCUMENT, FPDF_FILEWRITE*, FPDF_DWORD);

typedef FPDF_BITMAP (*fn_BitmapCreate)(int, int, int);
typedef void (*fn_BitmapFillRect)(FPDF_BITMAP, int, int, int, int, FPDF_DWORD);
typedef void (*fn_RenderPageBitmap)(FPDF_BITMAP, FPDF_PAGE, int, int, int, int, int, int);
typedef void* (*fn_BitmapGetBuffer)(FPDF_BITMAP);
typedef int (*fn_BitmapGetStride)(FPDF_BITMAP);
typedef void (*fn_BitmapDestroy)(FPDF_BITMAP);

static fn_InitLibrary p_InitLibrary;
static fn_DestroyLibrary p_DestroyLibrary;
static fn_GetLastError p_GetLastError;
static fn_LoadDocument p_LoadDocument;
static fn_CreateNewDocument p_CreateNewDocument;
static fn_CloseDocument p_CloseDocument;
static fn_GetPageCount p_GetPageCount;
static fn_CopyViewerPreferences p_CopyViewerPreferences;
static fn_LoadPage p_LoadPage;
static fn_ClosePage p_ClosePage;
static fn_PageNew p_PageNew;
static fn_DeletePage p_DeletePage;
static fn_GetPageWidthF p_GetPageWidthF;
static fn_GetPageHeightF p_GetPageHeightF;
static fn_PageGetMediaBox p_PageGetMediaBox;
static fn_PageSetMediaBox p_PageSetMediaBox;
static fn_PageGenerateContent p_PageGenerateContent;

static fn_TextLoadPage p_TextLoadPage;
static fn_TextClosePage p_TextClosePage;
static fn_TextCountChars p_TextCountChars;
static fn_TextGetUnicode p_TextGetUnicode;
static fn_TextGetTextObject p_TextGetTextObject;
static fn_TextIsGenerated p_TextIsGenerated;
static fn_TextGetCharBox p_TextGetCharBox;
static fn_TextGetLooseCharBox p_TextGetLooseCharBox;
static fn_TextGetCharAngle p_TextGetCharAngle;
static fn_TextGetFontSize p_TextGetFontSize;
static fn_TextGetFontInfo p_TextGetFontInfo;
static fn_TextGetFillColor p_TextGetFillColor;
static fn_TextObjGetFont p_TextObjGetFont;

static fn_PageCountObjects p_PageCountObjects;
static fn_PageGetObject p_PageGetObject;
static fn_PageRemoveObject p_PageRemoveObject;
static fn_PageObjDestroy p_PageObjDestroy;
static fn_PageObjGetType p_PageObjGetType;
static fn_PageObjGetBounds p_PageObjGetBounds;
static fn_PageObjTransform p_PageObjTransform;
static fn_PageObjGetFillColor p_PageObjGetFillColor;
static fn_PageObjSetFillColor p_PageObjSetFillColor;
static fn_PageObjGetFillColor p_PageObjGetStrokeColor;
static fn_PageObjSetFillColor p_PageObjSetStrokeColor;
static fn_TextObjGetText p_TextObjGetText;
static fn_TextObjGetFontSize p_TextObjGetFontSize;

static fn_TextLoadFont p_TextLoadFont;
static fn_TextLoadStandardFont p_TextLoadStandardFont;
static fn_FontClose p_FontClose;
static fn_PageObjCreateTextObj p_PageObjCreateTextObj;
static fn_TextSetText p_TextSetText;
static fn_PageInsertObject p_PageInsertObject;

static fn_PageObjCreateNewRect p_PageObjCreateNewRect;
static fn_PathSetDrawMode p_PathSetDrawMode;

static fn_ImportPages p_ImportPages;
static fn_ImportNPagesToOne p_ImportNPagesToOne;
static fn_SaveAsCopy p_SaveAsCopy;

static fn_BitmapCreate p_BitmapCreate;
static fn_BitmapFillRect p_BitmapFillRect;
static fn_RenderPageBitmap p_RenderPageBitmap;
static fn_BitmapGetBuffer p_BitmapGetBuffer;
static fn_BitmapGetStride p_BitmapGetStride;
static fn_BitmapDestroy p_BitmapDestroy;

static int resolve_symbols(void* h) {
    #define LOAD_SYM(var, name) do { \
        var = (typeof(var))dlsym(h, name); \
        if (!var) return 0; \
    } while (0)

    LOAD_SYM(p_InitLibrary, "FPDF_InitLibrary");
    LOAD_SYM(p_DestroyLibrary, "FPDF_DestroyLibrary");
    LOAD_SYM(p_GetLastError, "FPDF_GetLastError");
    LOAD_SYM(p_LoadDocument, "FPDF_LoadDocument");
    LOAD_SYM(p_CreateNewDocument, "FPDF_CreateNewDocument");
    LOAD_SYM(p_CloseDocument, "FPDF_CloseDocument");
    LOAD_SYM(p_GetPageCount, "FPDF_GetPageCount");
    LOAD_SYM(p_CopyViewerPreferences, "FPDF_CopyViewerPreferences");
    LOAD_SYM(p_LoadPage, "FPDF_LoadPage");
    LOAD_SYM(p_ClosePage, "FPDF_ClosePage");
    LOAD_SYM(p_PageNew, "FPDFPage_New");
    LOAD_SYM(p_DeletePage, "FPDFPage_Delete");
    LOAD_SYM(p_GetPageWidthF, "FPDF_GetPageWidthF");
    LOAD_SYM(p_GetPageHeightF, "FPDF_GetPageHeightF");
    LOAD_SYM(p_PageGetMediaBox, "FPDFPage_GetMediaBox");
    LOAD_SYM(p_PageSetMediaBox, "FPDFPage_SetMediaBox");
    LOAD_SYM(p_PageGenerateContent, "FPDFPage_GenerateContent");

    LOAD_SYM(p_TextLoadPage, "FPDFText_LoadPage");
    LOAD_SYM(p_TextClosePage, "FPDFText_ClosePage");
    LOAD_SYM(p_TextCountChars, "FPDFText_CountChars");
    LOAD_SYM(p_TextGetUnicode, "FPDFText_GetUnicode");
    LOAD_SYM(p_TextGetTextObject, "FPDFText_GetTextObject");
    LOAD_SYM(p_TextIsGenerated, "FPDFText_IsGenerated");
    LOAD_SYM(p_TextGetCharBox, "FPDFText_GetCharBox");
    LOAD_SYM(p_TextGetLooseCharBox, "FPDFText_GetLooseCharBox");
    LOAD_SYM(p_TextGetCharAngle, "FPDFText_GetCharAngle");
    LOAD_SYM(p_TextGetFontSize, "FPDFText_GetFontSize");
    LOAD_SYM(p_TextGetFontInfo, "FPDFText_GetFontInfo");
    LOAD_SYM(p_TextGetFillColor, "FPDFText_GetFillColor");
    LOAD_SYM(p_TextObjGetFont, "FPDFTextObj_GetFont");

    LOAD_SYM(p_PageCountObjects, "FPDFPage_CountObjects");
    LOAD_SYM(p_PageGetObject, "FPDFPage_GetObject");
    LOAD_SYM(p_PageRemoveObject, "FPDFPage_RemoveObject");
    LOAD_SYM(p_PageObjDestroy, "FPDFPageObj_Destroy");
    LOAD_SYM(p_PageObjGetType, "FPDFPageObj_GetType");
    LOAD_SYM(p_PageObjGetBounds, "FPDFPageObj_GetBounds");
    LOAD_SYM(p_PageObjTransform, "FPDFPageObj_Transform");
    LOAD_SYM(p_PageObjGetFillColor, "FPDFPageObj_GetFillColor");
    LOAD_SYM(p_PageObjSetFillColor, "FPDFPageObj_SetFillColor");
    LOAD_SYM(p_PageObjGetStrokeColor, "FPDFPageObj_GetStrokeColor");
    LOAD_SYM(p_PageObjSetStrokeColor, "FPDFPageObj_SetStrokeColor");
    LOAD_SYM(p_TextObjGetText, "FPDFTextObj_GetText");
    LOAD_SYM(p_TextObjGetFontSize, "FPDFTextObj_GetFontSize");

    LOAD_SYM(p_TextLoadFont, "FPDFText_LoadFont");
    LOAD_SYM(p_TextLoadStandardFont, "FPDFText_LoadStandardFont");
    LOAD_SYM(p_FontClose, "FPDFFont_Close");
    LOAD_SYM(p_PageObjCreateTextObj, "FPDFPageObj_CreateTextObj");
    LOAD_SYM(p_TextSetText, "FPDFText_SetText");
    LOAD_SYM(p_PageInsertObject, "FPDFPage_InsertObject");

    LOAD_SYM(p_PageObjCreateNewRect, "FPDFPageObj_CreateNewRect");
    LOAD_SYM(p_PathSetDrawMode, "FPDFPath_SetDrawMode");

    LOAD_SYM(p_ImportPages, "FPDF_ImportPages");
    LOAD_SYM(p_ImportNPagesToOne, "FPDF_ImportNPagesToOne");
    LOAD_SYM(p_SaveAsCopy, "FPDF_SaveAsCopy");

    LOAD_SYM(p_BitmapCreate, "FPDFBitmap_Create");
    LOAD_SYM(p_BitmapFillRect, "FPDFBitmap_FillRect");
    LOAD_SYM(p_RenderPageBitmap, "FPDF_RenderPageBitmap");
    LOAD_SYM(p_BitmapGetBuffer, "FPDFBitmap_GetBuffer");
    LOAD_SYM(p_BitmapGetStride, "FPDFBitmap_GetStride");
    LOAD_SYM(p_BitmapDestroy, "FPDFBitmap_Destroy");

    #undef LOAD_SYM
    return 1;
}

static int try_open_path(const char* path) {
    if (!path || !path[0]) return 0;
    void* h = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!h) return 0;
    if (!resolve_symbols(h)) {
        dlclose(h);
        return 0;
    }
    g_handle = h;
    strncpy(g_loaded_path, path, sizeof(g_loaded_path) - 1);
    p_InitLibrary();
    return 1;
}

int cpdfium_load_library(const char* explicit_path) {
    if (g_handle) return 1;
    if (explicit_path && try_open_path(explicit_path)) return 1;

    const char* env_path = getenv("PDFIUM_DYLIB_PATH");
    if (env_path && try_open_path(env_path)) return 1;

    // Executable-relative paths (App bundle Frameworks or build folder)
    char exec_path[1024] = {0};
    uint32_t size = sizeof(exec_path);
    if (_NSGetExecutablePath(exec_path, &size) == 0) {
        char* last_slash = strrchr(exec_path, '/');
        if (last_slash) {
            *last_slash = '\0';
            char candidate[1024];
            snprintf(candidate, sizeof(candidate), "%s/../Frameworks/libpdfium.dylib", exec_path);
            if (try_open_path(candidate)) return 1;
            snprintf(candidate, sizeof(candidate), "%s/libpdfium.dylib", exec_path);
            if (try_open_path(candidate)) return 1;
        }
    }

    // Standard workspace and local locations
    const char* candidates[] = {
        "Packages/CPDFium/PDFium.xcframework/macos-arm64/libpdfium.dylib",
        "Packages/CPDFium/lib/libpdfium.dylib",
        "/Users/ruoshui/vibecoding/pdf翻译/Packages/CPDFium/PDFium.xcframework/macos-arm64/libpdfium.dylib",
        "/Users/ruoshui/vibecoding/pdf翻译/Packages/CPDFium/lib/libpdfium.dylib",
        "/tmp/pdfium/lib/libpdfium.dylib",
        "libpdfium.dylib",
        NULL
    };
    for (int i = 0; candidates[i] != NULL; ++i) {
        if (try_open_path(candidates[i])) return 1;
    }
    return 0;
}

int cpdfium_is_loaded(void) {
    if (!g_handle) {
        cpdfium_load_library(NULL);
    }
    return g_handle != NULL ? 1 : 0;
}

const char* cpdfium_loaded_path(void) {
    return g_loaded_path;
}

void cpdfium_InitLibrary(void) { if (cpdfium_is_loaded()) p_InitLibrary(); }
void cpdfium_DestroyLibrary(void) { if (g_handle && p_DestroyLibrary) p_DestroyLibrary(); }
unsigned long cpdfium_GetLastError(void) { return cpdfium_is_loaded() ? p_GetLastError() : FPDF_ERR_UNKNOWN; }

FPDF_DOCUMENT cpdfium_LoadDocument(FPDF_BYTESTRING file_path, FPDF_BYTESTRING password) {
    return cpdfium_is_loaded() ? p_LoadDocument(file_path, password) : NULL;
}
FPDF_DOCUMENT cpdfium_CreateNewDocument(void) {
    return cpdfium_is_loaded() ? p_CreateNewDocument() : NULL;
}
void cpdfium_CloseDocument(FPDF_DOCUMENT document) {
    if (cpdfium_is_loaded() && document) p_CloseDocument(document);
}
int cpdfium_GetPageCount(FPDF_DOCUMENT document) {
    return (cpdfium_is_loaded() && document) ? p_GetPageCount(document) : 0;
}
FPDF_BOOL cpdfium_CopyViewerPreferences(FPDF_DOCUMENT dest_doc, FPDF_DOCUMENT src_doc) {
    return (cpdfium_is_loaded() && dest_doc && src_doc) ? p_CopyViewerPreferences(dest_doc, src_doc) : 0;
}

FPDF_PAGE cpdfium_LoadPage(FPDF_DOCUMENT document, int page_index) {
    return (cpdfium_is_loaded() && document) ? p_LoadPage(document, page_index) : NULL;
}
void cpdfium_ClosePage(FPDF_PAGE page) {
    if (cpdfium_is_loaded() && page) p_ClosePage(page);
}
FPDF_PAGE cpdfium_PageNew(FPDF_DOCUMENT document, int page_index, double width, double height) {
    return (cpdfium_is_loaded() && document) ? p_PageNew(document, page_index, width, height) : NULL;
}
void cpdfium_DeletePage(FPDF_DOCUMENT document, int page_index) {
    if (cpdfium_is_loaded() && document) p_DeletePage(document, page_index);
}
float cpdfium_GetPageWidthF(FPDF_PAGE page) {
    return (cpdfium_is_loaded() && page) ? p_GetPageWidthF(page) : 0.0f;
}
float cpdfium_GetPageHeightF(FPDF_PAGE page) {
    return (cpdfium_is_loaded() && page) ? p_GetPageHeightF(page) : 0.0f;
}
FPDF_BOOL cpdfium_PageGetMediaBox(FPDF_PAGE page, float* left, float* bottom, float* right, float* top) {
    return (cpdfium_is_loaded() && page) ? p_PageGetMediaBox(page, left, bottom, right, top) : 0;
}
FPDF_BOOL cpdfium_PageSetMediaBox(FPDF_PAGE page, float left, float bottom, float right, float top) {
    return (cpdfium_is_loaded() && page) ? p_PageSetMediaBox(page, left, bottom, right, top) : 0;
}
FPDF_BOOL cpdfium_PageGenerateContent(FPDF_PAGE page) {
    return (cpdfium_is_loaded() && page) ? p_PageGenerateContent(page) : 0;
}

FPDF_TEXTPAGE cpdfium_TextLoadPage(FPDF_PAGE page) {
    return (cpdfium_is_loaded() && page) ? p_TextLoadPage(page) : NULL;
}
void cpdfium_TextClosePage(FPDF_TEXTPAGE text_page) {
    if (cpdfium_is_loaded() && text_page) p_TextClosePage(text_page);
}
int cpdfium_TextCountChars(FPDF_TEXTPAGE text_page) {
    return (cpdfium_is_loaded() && text_page) ? p_TextCountChars(text_page) : 0;
}
unsigned int cpdfium_TextGetUnicode(FPDF_TEXTPAGE text_page, int index) {
    return (cpdfium_is_loaded() && text_page) ? p_TextGetUnicode(text_page, index) : 0;
}
FPDF_PAGEOBJECT cpdfium_TextGetTextObject(FPDF_TEXTPAGE text_page, int index) {
    return (cpdfium_is_loaded() && text_page) ? p_TextGetTextObject(text_page, index) : NULL;
}
int cpdfium_TextIsGenerated(FPDF_TEXTPAGE text_page, int index) {
    return (cpdfium_is_loaded() && text_page) ? p_TextIsGenerated(text_page, index) : 0;
}
FPDF_BOOL cpdfium_TextGetCharBox(FPDF_TEXTPAGE text_page, int index, double* left, double* right, double* bottom, double* top) {
    return (cpdfium_is_loaded() && text_page) ? p_TextGetCharBox(text_page, index, left, right, bottom, top) : 0;
}
FPDF_BOOL cpdfium_TextGetLooseCharBox(FPDF_TEXTPAGE text_page, int index, FS_RECTF* rect) {
    return (cpdfium_is_loaded() && text_page && rect) ? p_TextGetLooseCharBox(text_page, index, rect) : 0;
}
float cpdfium_TextGetCharAngle(FPDF_TEXTPAGE text_page, int index) {
    return (cpdfium_is_loaded() && text_page && p_TextGetCharAngle) ? p_TextGetCharAngle(text_page, index) : 0.0f;
}
double cpdfium_TextGetFontSize(FPDF_TEXTPAGE text_page, int index) {
    return (cpdfium_is_loaded() && text_page) ? p_TextGetFontSize(text_page, index) : 0.0;
}
unsigned long cpdfium_TextGetFontInfo(FPDF_TEXTPAGE text_page, int index, void* buffer, unsigned long buflen, int* flags) {
    return (cpdfium_is_loaded() && text_page) ? p_TextGetFontInfo(text_page, index, buffer, buflen, flags) : 0;
}
FPDF_BOOL cpdfium_TextGetFillColor(FPDF_TEXTPAGE text_page, int index, unsigned int* R, unsigned int* G, unsigned int* B, unsigned int* A) {
    return (cpdfium_is_loaded() && text_page) ? p_TextGetFillColor(text_page, index, R, G, B, A) : 0;
}
FPDF_FONT cpdfium_TextObjGetFont(FPDF_PAGEOBJECT text_object) {
    return (cpdfium_is_loaded() && text_object) ? p_TextObjGetFont(text_object) : NULL;
}

int cpdfium_PageCountObjects(FPDF_PAGE page) {
    return (cpdfium_is_loaded() && page) ? p_PageCountObjects(page) : 0;
}
FPDF_PAGEOBJECT cpdfium_PageGetObject(FPDF_PAGE page, int index) {
    return (cpdfium_is_loaded() && page) ? p_PageGetObject(page, index) : NULL;
}
FPDF_BOOL cpdfium_PageRemoveObject(FPDF_PAGE page, FPDF_PAGEOBJECT page_obj) {
    return (cpdfium_is_loaded() && page && page_obj) ? p_PageRemoveObject(page, page_obj) : 0;
}
void cpdfium_PageObjDestroy(FPDF_PAGEOBJECT page_obj) {
    if (cpdfium_is_loaded() && page_obj) p_PageObjDestroy(page_obj);
}
int cpdfium_PageObjGetType(FPDF_PAGEOBJECT page_obj) {
    return (cpdfium_is_loaded() && page_obj) ? p_PageObjGetType(page_obj) : FPDF_PAGEOBJ_UNKNOWN;
}
FPDF_BOOL cpdfium_PageObjGetBounds(FPDF_PAGEOBJECT page_obj, float* left, float* bottom, float* right, float* top) {
    return (cpdfium_is_loaded() && page_obj) ? p_PageObjGetBounds(page_obj, left, bottom, right, top) : 0;
}
void cpdfium_PageObjTransform(FPDF_PAGEOBJECT page_obj, double a, double b, double c, double d, double e, double f) {
    if (cpdfium_is_loaded() && page_obj) p_PageObjTransform(page_obj, a, b, c, d, e, f);
}
FPDF_BOOL cpdfium_PageObjGetFillColor(FPDF_PAGEOBJECT page_obj, unsigned int* R, unsigned int* G, unsigned int* B, unsigned int* A) {
    return (cpdfium_is_loaded() && page_obj) ? p_PageObjGetFillColor(page_obj, R, G, B, A) : 0;
}
FPDF_BOOL cpdfium_PageObjSetFillColor(FPDF_PAGEOBJECT page_obj, unsigned int R, unsigned int G, unsigned int B, unsigned int A) {
    return (cpdfium_is_loaded() && page_obj) ? p_PageObjSetFillColor(page_obj, R, G, B, A) : 0;
}
FPDF_BOOL cpdfium_PageObjGetStrokeColor(FPDF_PAGEOBJECT page_obj, unsigned int* R, unsigned int* G, unsigned int* B, unsigned int* A) {
    return (cpdfium_is_loaded() && page_obj) ? p_PageObjGetStrokeColor(page_obj, R, G, B, A) : 0;
}
FPDF_BOOL cpdfium_PageObjSetStrokeColor(FPDF_PAGEOBJECT page_obj, unsigned int R, unsigned int G, unsigned int B, unsigned int A) {
    return (cpdfium_is_loaded() && page_obj) ? p_PageObjSetStrokeColor(page_obj, R, G, B, A) : 0;
}
unsigned long cpdfium_TextObjGetText(FPDF_PAGEOBJECT text_object, FPDF_TEXTPAGE text_page, FPDF_WCHAR* buffer, unsigned long length) {
    return (cpdfium_is_loaded() && text_object && text_page) ? p_TextObjGetText(text_object, text_page, buffer, length) : 0;
}
FPDF_BOOL cpdfium_TextObjGetFontSize(FPDF_PAGEOBJECT text_object, float* size) {
    return (cpdfium_is_loaded() && text_object && size) ? p_TextObjGetFontSize(text_object, size) : 0;
}

FPDF_FONT cpdfium_TextLoadFont(FPDF_DOCUMENT document, const uint8_t* data, uint32_t size, int font_type, FPDF_BOOL cid) {
    return (cpdfium_is_loaded() && document && data) ? p_TextLoadFont(document, data, size, font_type, cid) : NULL;
}
FPDF_FONT cpdfium_TextLoadStandardFont(FPDF_DOCUMENT document, FPDF_BYTESTRING font) {
    return (cpdfium_is_loaded() && document && font) ? p_TextLoadStandardFont(document, font) : NULL;
}
void cpdfium_FontClose(FPDF_FONT font) {
    if (cpdfium_is_loaded() && font) p_FontClose(font);
}
FPDF_PAGEOBJECT cpdfium_PageObjCreateTextObj(FPDF_DOCUMENT document, FPDF_FONT font, float font_size) {
    return (cpdfium_is_loaded() && document && font) ? p_PageObjCreateTextObj(document, font, font_size) : NULL;
}
FPDF_BOOL cpdfium_TextSetText(FPDF_PAGEOBJECT text_object, const FPDF_WCHAR* text) {
    return (cpdfium_is_loaded() && text_object && text) ? p_TextSetText(text_object, text) : 0;
}
void cpdfium_PageInsertObject(FPDF_PAGE page, FPDF_PAGEOBJECT page_obj) {
    if (cpdfium_is_loaded() && page && page_obj) p_PageInsertObject(page, page_obj);
}

FPDF_PAGEOBJECT cpdfium_PageObjCreateNewRect(float x, float y, float w, float h) {
    return cpdfium_is_loaded() ? p_PageObjCreateNewRect(x, y, w, h) : NULL;
}
FPDF_BOOL cpdfium_PathSetDrawMode(FPDF_PAGEOBJECT path, int fillmode, FPDF_BOOL stroke) {
    return (cpdfium_is_loaded() && path) ? p_PathSetDrawMode(path, fillmode, stroke) : 0;
}

FPDF_BOOL cpdfium_ImportPages(FPDF_DOCUMENT dest_doc, FPDF_DOCUMENT src_doc, FPDF_BYTESTRING pagerange, int index) {
    return (cpdfium_is_loaded() && dest_doc && src_doc) ? p_ImportPages(dest_doc, src_doc, pagerange, index) : 0;
}
FPDF_DOCUMENT cpdfium_ImportNPagesToOne(FPDF_DOCUMENT src_doc, float output_width, float output_height, size_t num_pages_on_x_axis, size_t num_pages_on_y_axis) {
    return (cpdfium_is_loaded() && src_doc) ? p_ImportNPagesToOne(src_doc, output_width, output_height, num_pages_on_x_axis, num_pages_on_y_axis) : NULL;
}

typedef struct {
    FILE* fp;
} FileWriteContext;

typedef struct {
    FPDF_FILEWRITE base;
    FILE* fp;
} CustomFileWrite;

static int write_block_callback(struct FPDF_FILEWRITE_* pThis, const void* pData, unsigned long size) {
    CustomFileWrite* cfw = (CustomFileWrite*)pThis;
    if (!cfw || !cfw->fp) return 0;
    size_t written = fwrite(pData, 1, size, cfw->fp);
    return (written == size) ? 1 : 0;
}

FPDF_BOOL cpdfium_SaveDocumentToPath(FPDF_DOCUMENT document, const char* file_path) {
    if (!cpdfium_is_loaded() || !document || !file_path) return 0;
    FILE* fp = fopen(file_path, "wb");
    if (!fp) return 0;
    CustomFileWrite cfw;
    memset(&cfw, 0, sizeof(cfw));
    cfw.base.version = 1;
    cfw.base.WriteBlock = write_block_callback;
    cfw.fp = fp;
    FPDF_BOOL ok = p_SaveAsCopy(document, (FPDF_FILEWRITE*)&cfw, 0);
    fclose(fp);
    return ok;
}

FPDF_BITMAP cpdfium_BitmapCreate(int width, int height, int alpha) {
    return cpdfium_is_loaded() ? p_BitmapCreate(width, height, alpha) : NULL;
}
void cpdfium_BitmapFillRect(FPDF_BITMAP bitmap, int left, int top, int width, int height, FPDF_DWORD color) {
    if (cpdfium_is_loaded() && bitmap) p_BitmapFillRect(bitmap, left, top, width, height, color);
}
void cpdfium_RenderPageBitmap(FPDF_BITMAP bitmap, FPDF_PAGE page, int start_x, int start_y, int size_x, int size_y, int rotate, int flags) {
    if (cpdfium_is_loaded() && bitmap && page) p_RenderPageBitmap(bitmap, page, start_x, start_y, size_x, size_y, rotate, flags);
}
void* cpdfium_BitmapGetBuffer(FPDF_BITMAP bitmap) {
    return (cpdfium_is_loaded() && bitmap) ? p_BitmapGetBuffer(bitmap) : NULL;
}
int cpdfium_BitmapGetStride(FPDF_BITMAP bitmap) {
    return (cpdfium_is_loaded() && bitmap) ? p_BitmapGetStride(bitmap) : 0;
}
void cpdfium_BitmapDestroy(FPDF_BITMAP bitmap) {
    if (cpdfium_is_loaded() && bitmap) p_BitmapDestroy(bitmap);
}
