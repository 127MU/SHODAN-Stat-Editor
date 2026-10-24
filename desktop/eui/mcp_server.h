#pragma once
#include "bridge.h"
#include <atomic>
#include <functional>
#include <future>
#include <mutex>
#include <thread>
#include <deque>
namespace shodan {
Value object(std::initializer_list<std::pair<const std::string,Value>> fields);
Value jsonParse(const std::string& text);
std::string jsonEncode(const Value& value);
struct McpRequest {
 std::string name;Value arguments;std::promise<Value> response;std::atomic<bool> cancelled{false};
};
class McpServer {
 std::atomic<bool> running{false};std::thread worker;std::mutex mutex;
 std::deque<std::shared_ptr<McpRequest>> pending;std::deque<std::string> history;
 Value tools;std::string secret;unsigned short boundPort=0;std::function<void()> wake;
 void serve(std::uintptr_t listener);void record(const std::string& message);
public:
 ~McpServer();
 void start(Value catalog,std::function<void()> onRequest);
 void stop();bool enabled()const{return running;}
 std::string endpoint()const;const std::string& token()const{return secret;}
 std::shared_ptr<McpRequest> take();Value logs();
};
}
