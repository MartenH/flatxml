#include "pugixml.hpp"
#include <chrono>
#include <cstdio>
#include <vector>

int main(int argc, char** argv) {
    FILE* f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<char> buf(n);
    if (fread(buf.data(), 1, n, f) != (size_t)n) { printf("error: short read\n"); return 1; }
    fclose(f);
    auto t = std::chrono::steady_clock::now();
    pugi::xml_document doc;
    // in place, as flatxml reads its mapped file: the tree points into the buffer
    pugi::xml_parse_result r = doc.load_buffer_inplace(buf.data(), n, pugi::parse_default);
    double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t).count();
    if (!r) { printf("error: %s\n", r.description()); return 1; }
    printf("pugixml: %.1f ms, %.0f MB/s\n", s * 1e3, n / 1048576.0 / s);
    return 0;
}
