#include <hello.h>

#include <iostream>

int main() {
    char buf[128];
    hello_message(buf, sizeof buf);
    std::cout << buf << ", pkg-config hello " HELLO_PC_VERSION "\n";
}
