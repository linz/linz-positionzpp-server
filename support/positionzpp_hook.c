#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>
 
int main( int argc, char *argv[] )
{
    char command[512];
    if( argc == 3 )
    {
        sprintf(command,"%s \"%.20s\" \"%.400s\"",
            "/usr/local/bin/positionzpp_hook.sh",
            argv[1],
            argv[2]);
        // setuid(0);
        system(command);
    }
    return 0;
}
