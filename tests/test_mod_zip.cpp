#include "../desktop/eui/mod_zip.h"
#include <cassert>
#include <iostream>
int main(int argc,char** argv){std::filesystem::path p=argv[1];
 for(auto name:{"stored.zip","deflated.zip","escaped.zip"}){auto z=shodan::readModZip(p/name);assert(z.files.size()==1);assert(z.files[0].data==std::string("abc\0def",7));assert(z.title=="测试模组"&&!z.description.empty());shodan::writeModZip(p/"roundtrip.zip",z.files);assert(shodan::readModZip(p/"roundtrip.zip").files[0].data==z.files[0].data);}
 for(auto name:{"unsafe.zip","badcrc.zip"}){bool rejected=false;try{shodan::readModZip(p/name);}catch(...){rejected=true;}assert(rejected);}
 std::cout<<"ZIP stored/deflate, metadata, binary roundtrip, unsafe paths and CRC passed\n";
}