#include "hello.h"

#include <stdio.h>

#include "generated.h"

int hello_message(char *buf, int size) {
    return snprintf(buf, size, "hello from %s", HELLO_GENERATED);
}
