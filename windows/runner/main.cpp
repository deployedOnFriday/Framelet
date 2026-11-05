#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Renderer backend A/B measured on Intel Iris Xe (2026-11):
  //   Impeller: raster p50 = 22.9ms (janky, suspected slow path on
  //             this iGPU/driver), Skia: raster p50 = 3.5ms with a
  //             one-time ~1.3s shader-compilation spike per launch.
  // Smoothness wins: default to Skia until Impeller's Windows backend
  // matures. Run framelet.exe --enable-impeller to A/B test again.
  bool impeller_enabled = false;
  for (const auto &arg : GetCommandLineArguments()) {
    if (arg == "--enable-impeller") impeller_enabled = true;
  }
  project.set_impeller_switch(impeller_enabled
                                  ? flutter::ImpellerSwitch::Enabled
                                  : flutter::ImpellerSwitch::Disabled);

  FlutterWindow window(project);
  Win32Window::Point origin(40, 40);
  Win32Window::Size size(1440, 960);
  // Window title is written as Unicode escapes: MSVC parses sources with the
  // local code page by default, so literal CJK text turns into mojibake.
  if (!window.Create(L"\u62FE\u5E27 - Framelet", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
