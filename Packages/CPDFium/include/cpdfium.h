#ifndef CPDFIUM_H
#define CPDFIUM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// PDFium opaque handle types
typedef void* FPDF_DOCUMENT;
typedef void* FPDF_PAGE;
typedef void* FPDF_TEXTPAGE;
typedef void* FPDF_PAGEOBJECT;
typedef void* FPDF_FONT;
typedef void* FPDF_BITMAP;
typedef void* FPDF_BOOKMARK;

typedef int FPDF_BOOL;
typedef int FPDF_ERROR;
typedef unsigned long FPDF_DWORD;
typedef unsigned short FPDF_WCHAR;
typedef const char* FPDF_BYTESTRING;

// Constants
#define FPDF_OBJECT_UNKNOWN 0
#define FPDF_OBJECT_BOOLEAN 1
#define FPDF_OBJECT_NUMBER 2
#define FPDF_OBJECT_STRING 3
#define FPDF_OBJECT_NAME 4
#define FPDF_OBJECT_ARRAY 5
#define FPDF_OBJECT_DICTIONARY 6
#define FPDF_OBJECT_STREAM 7
#define FPDF_OBJECT_NULLOBJ 8
#define FPDF_OBJECT_REFERENCE 9

// Page object types
#define FPDF_PAGEOBJ_UNKNOWN 0
#define FPDF_PAGEOBJ_TEXT 1
#define FPDF_PAGEOBJ_PATH 2
#define FPDF_PAGEOBJ_IMAGE 3
#define FPDF_PAGEOBJ_SHADING 4
#define FPDF_PAGEOBJ_FORM 5

// Font types
#define FPDF_FONT_TYPE1 1
#define FPDF_FONT_TRUETYPE 2

// Error codes
#define FPDF_ERR_SUCCESS 0
#define FPDF_ERR_UNKNOWN 1
#define FPDF_ERR_FILE 2
#define FPDF_ERR_FORMAT 3
#define FPDF_ERR_PASSWORD 4
#define FPDF_ERR_SECURITY 5
#define FPDF_ERR_PAGE 6

// Render flags
#define FPDF_ANNOT 0x01
#define FPDF_LCD_TEXT 0x02
#define FPDF_PRINTING 0x800

typedef struct FS_MATRIX_ {
    float a;
    float b;
    float c;
    float d;
    float e;
    float f;
} FS_MATRIX;

typedef struct FS_RECTF_ {
    float left;
    float top;
    float right;
    float bottom;
} FS_RECTF;

typedef struct FPDF_FILEWRITE_ {
    int version;
    int (*WriteBlock)(struct FPDF_FILEWRITE_* pThis, const void* pData, unsigned long size);
} FPDF_FILEWRITE;

// Loader / availability API
int cpdfium_load_library(const char* explicit_path);
int cpdfium_is_loaded(void);
const char* cpdfium_loaded_path(void);

// Lifecycle
void cpdfium_InitLibrary(void);
void cpdfium_DestroyLibrary(void);
unsigned long cpdfium_GetLastError(void);

// Document operations
FPDF_DOCUMENT cpdfium_LoadDocument(FPDF_BYTESTRING file_path, FPDF_BYTESTRING password);
FPDF_DOCUMENT cpdfium_CreateNewDocument(void);
void cpdfium_CloseDocument(FPDF_DOCUMENT document);
int cpdfium_GetPageCount(FPDF_DOCUMENT document);
FPDF_BOOL cpdfium_CopyViewerPreferences(FPDF_DOCUMENT dest_doc, FPDF_DOCUMENT src_doc);

// Page operations
FPDF_PAGE cpdfium_LoadPage(FPDF_DOCUMENT document, int page_index);
void cpdfium_ClosePage(FPDF_PAGE page);
FPDF_PAGE cpdfium_PageNew(FPDF_DOCUMENT document, int page_index, double width, double height);
void cpdfium_DeletePage(FPDF_DOCUMENT document, int page_index);
float cpdfium_GetPageWidthF(FPDF_PAGE page);
float cpdfium_GetPageHeightF(FPDF_PAGE page);
FPDF_BOOL cpdfium_PageGetMediaBox(FPDF_PAGE page, float* left, float* bottom, float* right, float* top);
FPDF_BOOL cpdfium_PageSetMediaBox(FPDF_PAGE page, float left, float bottom, float right, float top);
FPDF_BOOL cpdfium_PageGenerateContent(FPDF_PAGE page);

// Text extraction operations
FPDF_TEXTPAGE cpdfium_TextLoadPage(FPDF_PAGE page);
void cpdfium_TextClosePage(FPDF_TEXTPAGE text_page);
int cpdfium_TextCountChars(FPDF_TEXTPAGE text_page);
unsigned int cpdfium_TextGetUnicode(FPDF_TEXTPAGE text_page, int index);
FPDF_PAGEOBJECT cpdfium_TextGetTextObject(FPDF_TEXTPAGE text_page, int index);
int cpdfium_TextIsGenerated(FPDF_TEXTPAGE text_page, int index);
FPDF_BOOL cpdfium_TextGetCharBox(FPDF_TEXTPAGE text_page, int index, double* left, double* right, double* bottom, double* top);
FPDF_BOOL cpdfium_TextGetLooseCharBox(FPDF_TEXTPAGE text_page, int index, FS_RECTF* rect);
float cpdfium_TextGetCharAngle(FPDF_TEXTPAGE text_page, int index);
double cpdfium_TextGetFontSize(FPDF_TEXTPAGE text_page, int index);
unsigned long cpdfium_TextGetFontInfo(FPDF_TEXTPAGE text_page, int index, void* buffer, unsigned long buflen, int* flags);
FPDF_BOOL cpdfium_TextGetFillColor(FPDF_TEXTPAGE text_page, int index, unsigned int* R, unsigned int* G, unsigned int* B, unsigned int* A);
FPDF_FONT cpdfium_TextObjGetFont(FPDF_PAGEOBJECT text_object);

// Page object enumeration & editing
int cpdfium_PageCountObjects(FPDF_PAGE page);
FPDF_PAGEOBJECT cpdfium_PageGetObject(FPDF_PAGE page, int index);
FPDF_BOOL cpdfium_PageRemoveObject(FPDF_PAGE page, FPDF_PAGEOBJECT page_obj);
void cpdfium_PageObjDestroy(FPDF_PAGEOBJECT page_obj);
int cpdfium_PageObjGetType(FPDF_PAGEOBJECT page_obj);
FPDF_BOOL cpdfium_PageObjGetBounds(FPDF_PAGEOBJECT page_obj, float* left, float* bottom, float* right, float* top);
void cpdfium_PageObjTransform(FPDF_PAGEOBJECT page_obj, double a, double b, double c, double d, double e, double f);
FPDF_BOOL cpdfium_PageObjGetFillColor(FPDF_PAGEOBJECT page_obj, unsigned int* R, unsigned int* G, unsigned int* B, unsigned int* A);
FPDF_BOOL cpdfium_PageObjSetFillColor(FPDF_PAGEOBJECT page_obj, unsigned int R, unsigned int G, unsigned int B, unsigned int A);
FPDF_BOOL cpdfium_PageObjGetStrokeColor(FPDF_PAGEOBJECT page_obj, unsigned int* R, unsigned int* G, unsigned int* B, unsigned int* A);
FPDF_BOOL cpdfium_PageObjSetStrokeColor(FPDF_PAGEOBJECT page_obj, unsigned int R, unsigned int G, unsigned int B, unsigned int A);
unsigned long cpdfium_TextObjGetText(FPDF_PAGEOBJECT text_object, FPDF_TEXTPAGE text_page, FPDF_WCHAR* buffer, unsigned long length);
FPDF_BOOL cpdfium_TextObjGetFontSize(FPDF_PAGEOBJECT text_object, float* size);

// Font & Text creation
FPDF_FONT cpdfium_TextLoadFont(FPDF_DOCUMENT document, const uint8_t* data, uint32_t size, int font_type, FPDF_BOOL cid);
FPDF_FONT cpdfium_TextLoadStandardFont(FPDF_DOCUMENT document, FPDF_BYTESTRING font);
void cpdfium_FontClose(FPDF_FONT font);
FPDF_PAGEOBJECT cpdfium_PageObjCreateTextObj(FPDF_DOCUMENT document, FPDF_FONT font, float font_size);
FPDF_BOOL cpdfium_TextSetText(FPDF_PAGEOBJECT text_object, const FPDF_WCHAR* text);
void cpdfium_PageInsertObject(FPDF_PAGE page, FPDF_PAGEOBJECT page_obj);

// Path / Rect creation (for fallback background or annotations)
FPDF_PAGEOBJECT cpdfium_PageObjCreateNewRect(float x, float y, float w, float h);
FPDF_BOOL cpdfium_PathSetDrawMode(FPDF_PAGEOBJECT path, int fillmode, FPDF_BOOL stroke);

// Page import & N-up (for mono copy and dual side-by-side generation)
FPDF_BOOL cpdfium_ImportPages(FPDF_DOCUMENT dest_doc, FPDF_DOCUMENT src_doc, FPDF_BYTESTRING pagerange, int index);
FPDF_DOCUMENT cpdfium_ImportNPagesToOne(FPDF_DOCUMENT src_doc, float output_width, float output_height, size_t num_pages_on_x_axis, size_t num_pages_on_y_axis);

// Saving helper (writes directly to a file path on disk)
FPDF_BOOL cpdfium_SaveDocumentToPath(FPDF_DOCUMENT document, const char* file_path);

// Bitmap rendering
FPDF_BITMAP cpdfium_BitmapCreate(int width, int height, int alpha);
void cpdfium_BitmapFillRect(FPDF_BITMAP bitmap, int left, int top, int width, int height, FPDF_DWORD color);
void cpdfium_RenderPageBitmap(FPDF_BITMAP bitmap, FPDF_PAGE page, int start_x, int start_y, int size_x, int size_y, int rotate, int flags);
void* cpdfium_BitmapGetBuffer(FPDF_BITMAP bitmap);
int cpdfium_BitmapGetStride(FPDF_BITMAP bitmap);
void cpdfium_BitmapDestroy(FPDF_BITMAP bitmap);

#ifdef __cplusplus
}
#endif

#endif /* CPDFIUM_H */
