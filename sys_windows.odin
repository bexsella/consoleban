package main

import win32 "core:sys/windows"
import "core:fmt"

@(private)
std_in_handle := win32.GetStdHandle(win32.STD_INPUT_HANDLE)

@(private)
std_out_handle := win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)

@(private)
console_mode: u32

init_terminal :: proc() {
    std_in_handle := win32.GetStdHandle(win32.STD_INPUT_HANDLE)
    std_out_handle := win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)

    console_mode: u32

    win32.GetConsoleMode(std_out_handle, &console_mode)
    win32.SetConsoleMode(std_out_handle, console_mode | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
}

quit_terminal :: proc() {
    win32.SetConsoleMode(std_out_handle, console_mode)
}

process_keys :: proc(state: ^Game_State) -> bool {
    input_record_buf: [32]win32.INPUT_RECORD
    input_event_count: u32

    win32.ReadConsoleInputW(std_in_handle, &input_record_buf[0], len(input_record_buf), &input_event_count)

    if input_event_count > 0 {
        for i in 0..<input_event_count {
            #partial switch input_record_buf[i].EventType {
                case .KEY_EVENT:
                    key_event := input_record_buf[i].Event.KeyEvent

                    if key_event.bKeyDown == false do continue
                    if key_event.wRepeatCount > 1 do continue

                    switch key_event.wVirtualKeyCode {
                        case win32.VK_ESCAPE: return false
                        case win32.VK_UP: if    do_move(state.player, state, 0, -1, nil) { state.moves += 1 } else { fmt.print("\a") }
                        case win32.VK_DOWN: if  do_move(state.player, state, 0, 1, nil) { state.moves += 1 } else { fmt.print("\a") }
                        case win32.VK_LEFT: if  do_move(state.player, state, -1, 0, nil) { state.moves += 1 } else { fmt.print("\a") }
                        case win32.VK_RIGHT: if do_move(state.player, state, 1, 0, nil) { state.moves += 1 } else { fmt.print("\a") }
                        case win32.VK_R: init_map(state.map_data, state)
                        case:
                    }
                case:
            }
        }
    }

    return true
}

terminal_dimensions :: proc() -> [2]int {
    screen_info: win32.CONSOLE_SCREEN_BUFFER_INFO
    win32.GetConsoleScreenBufferInfo(std_out_handle, &screen_info)

    w := cast(int)screen_info.dwSize.X
    h := cast(int)screen_info.dwSize.Y

    return {w, h}
}
