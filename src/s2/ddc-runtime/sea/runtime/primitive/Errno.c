
// On Linux we need to define _GNU_SOURCE to expose strerror_r.
#define _GNU_SOURCE

#include <stdlib.h>
#include <errno.h>
#include <alloca.h>
#include <string.h>

#include "runtime/Primitive.h"


// Get the value of the 'errno' global.
int     ddcPrimErrnoGet ()
{
        return errno;
}

// Get the name of the given 'errno' value.
Obj*    ddcPrimErrnoShowMessage (int errno_val)
{
        // Write message into a temporary buffer.
        char* pBuf      = alloca(1024);

#ifdef __GLIBC__
        // GNU strerror_r returns a pointer to the result.
        char *pErrorMsg = strerror_r(errno_val, pBuf, 1024);
        if(!pErrorMsg) abort();
#else
        // XSI version always copies to the provided buffer and returns 0 on success.
        if (strerror_r(errno_val, pBuf, 1024) != 0) abort();
        char *pErrorMsg = pBuf;
#endif

        // Allocate a new vector to hold the message.
        int lenActual   = strlen(pErrorMsg);
        Obj* pVec       = ddcPrimVectorAlloc8(lenActual + 1);
        string_t* pPay  = (string_t*)ddcPrimVectorPayload8(pVec);

        // Copy data into the new vector.
        strncpy(pPay, pErrorMsg, lenActual);

        // Ensure there's a null character on the end of the string.
        *(pPay + lenActual) = 0;

        return pVec;
}

