package main  

import "core:sys/posix"

init_terminal :: proc() {
    // posix.term
}

quit_terminal :: proc() {

}

process_keys :: proc(state: ^Game_State) -> bool {
    return false
}
