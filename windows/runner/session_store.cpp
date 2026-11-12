#include "session_store.h"

#include <windows.h>
#include <dpapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;

std::string Argument(const flutter::EncodableMap& args, const char* name) {
  const auto found = args.find(Value(name));
  if (found == args.end()) throw std::runtime_error("Missing argument");
  return std::get<std::string>(found->second);
}

std::filesystem::path SessionPath(const std::string& key) {
  if (key.size() != 64 || key.find_first_not_of("0123456789abcdef") != std::string::npos) {
    throw std::runtime_error("Invalid key");
  }
  wchar_t local[MAX_PATH];
  const auto length = GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) throw std::runtime_error("Missing app directory");
  return std::filesystem::path(local) / L"Splav" / L"sessions" / (key + ".bin");
}

std::vector<BYTE> Protect(std::vector<BYTE>& bytes, bool encrypt) {
  DATA_BLOB input{static_cast<DWORD>(bytes.size()), bytes.data()};
  DATA_BLOB output{};
  const auto success = encrypt
      ? CryptProtectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)
      : CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output);
  if (!success) throw std::runtime_error("Protected storage failed");
  std::vector<BYTE> result(output.pbData, output.pbData + output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return result;
}
}  // namespace

void RegisterSessionStore(flutter::BinaryMessenger* messenger) {
  flutter::MethodChannel<Value> channel(messenger, "splav/session", &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([](const flutter::MethodCall<Value>& call,
                                std::unique_ptr<flutter::MethodResult<Value>> result) {
    try {
      if (!call.arguments()) throw std::runtime_error("Missing arguments");
      const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
      const auto path = SessionPath(Argument(args, "key"));
      if (call.method_name() == "read") {
        if (!std::filesystem::exists(path)) { result->Success(); return; }
        std::ifstream file(path, std::ios::binary);
        if (!file) throw std::runtime_error("Read failed");
        std::vector<BYTE> bytes((std::istreambuf_iterator<char>(file)), {});
        auto plain = Protect(bytes, false);
        result->Success(Value(std::string(plain.begin(), plain.end())));
        SecureZeroMemory(plain.data(), plain.size());
      } else if (call.method_name() == "write") {
        auto value = Argument(args, "value");
        std::vector<BYTE> plain(value.begin(), value.end());
        const auto encrypted = Protect(plain, true);
        SecureZeroMemory(plain.data(), plain.size());
        SecureZeroMemory(value.data(), value.size());
        std::filesystem::create_directories(path.parent_path());
        auto temporary = path;
        temporary += ".tmp";
        {
          std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
          file.write(reinterpret_cast<const char*>(encrypted.data()), encrypted.size());
          file.flush();
          if (!file) throw std::runtime_error("Write failed");
        }
        if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
          throw std::runtime_error("Replace failed");
        }
        result->Success();
      } else if (call.method_name() == "delete") {
        std::filesystem::remove(path);
        result->Success();
      } else {
        result->NotImplemented();
      }
    } catch (const std::exception&) {
      result->Error("session_storage", "Не удалось открыть защищённый сеанс");
    }
  });
}
