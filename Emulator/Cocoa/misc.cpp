#include "burner.h"

int bDrvSaveAll=0;
int nAppVirtualFps = 6000; // App fps * 100
bool bDoIpsPatch;
bool bRunPause=0;
int bDrvOkay = 0;
bool bAlwaysProcessKeyboardInput = 0;
TCHAR szAppHiscorePath[MAX_PATH];
TCHAR szAppSamplesPath[MAX_PATH];

bool AppProcessKeyboardInput()
{
	return true;
}

void IpsApplyPatches(UINT8 *, char *)
{
}

TCHAR* GetIsoPath()
{
    return NULL;
}

void Reinitialise(void)
{
}

void wav_pause(bool bResume)
{
}
