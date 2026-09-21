/*
 * Anchor translation unit for the crosstransfer_native shared library. The
 * static archives are pulled in whole (-force_load / --whole-archive); this
 * file only guarantees the library has at least one object of its own.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "crosstransfer/ct_api.h"

extern "C" CT_API const char* CtNativeVersion(void) { return CtVersion(); }
