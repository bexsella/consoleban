// 
// 
// 
// 
package main

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:fmt"
import "core:os"

import "vermin"

Max_Maps :: 16 // or whatever
Position :: distinct [2]int
Max_Entities :: 1024
Max_Map_Width :: 80
Max_Map_Height :: 80

// do this better, probably
Input :: struct {
    up: bool,
    down: bool,
    left: bool,
    right: bool,
    reset: bool,
    undo: bool,
    quit: bool
}

Game_State :: struct {
    num_entities: u32,
    num_boxes: u32,
    num_exits: u32,
    entities: [Max_Entities]Entity,
    entity_map: [Max_Map_Width*Max_Map_Height]int,
    map_data: ^Map_Data,
    map_index: int,
    player: ^Entity, // short hand to get into the entity map, we always want to "do move" from the player entity out
    num_moves: int,
    num_pushes: int,
    solved: bool
}

Map_Data :: struct {
    author, title: string,
    width, height: int, // largest width and height of the map row and column
    data: [Max_Map_Width*Max_Map_Height]u8
}

Entity_Type :: enum {
    Player,
    Box,
    Goal,
    Exit,
}

Entity_Flags :: enum {
    Moveable,
    Overlapped,
}

Entity_Flags_Set :: bit_set[Entity_Flags]

Entity :: struct {
    type: Entity_Type,
    position: Position,
    flags: Entity_Flags_Set,
    id: int,
    overlapped_id: int,
    enabled: bool // fucking enabled?
}

// memory more or less persistent over the run of a map
persistent_arena: virtual.Arena
persistent_allocator: mem.Allocator
history_states: [dynamic]Game_State
map_list: [dynamic]Map_Data
current_state: Game_State

load_sok :: proc(path: string) -> bool {
    valid_map_row :: proc(line: string) -> bool {
        puzzle_elements := []u8{'#', 'x', '.', '$', 'b', '@', 'p', '+', 'P', '*', 'B', ' ', '-', '_'}

        if len(line) == 0 {
            return false
        }

        for r in line {
            if strings.index_rune(string(puzzle_elements), r) < 0 {
                return false
            }
        }

        return true
    }

    // free all memory from any previously loaded map data including play history
    mem.free_all(persistent_allocator)

    err: mem.Allocator_Error
    map_list, err = make([dynamic]Map_Data, persistent_allocator)

    if err != nil {
        fmt.eprintln("Unable to allocate map list.")
        return false
    }

    if !os.exists(path) {
        fmt.eprintfln("Map file \"%s\" cannot be found.", path)
        return false
    }

    f, f_err := os.open(path)

    if f_err != nil {
        fmt.eprintfln("Failed to load \"%s\".", path)
        return false
    }

    data: []byte
    data, f_err = os.read_entire_file(f, context.temp_allocator)
    defer free_all(context.temp_allocator)

    if err != nil {
        fmt.eprintfln("Unable to read data from \"%s\".", path)
        return false
    }

    str := string(data)

    max_len := -1
    line_num := 0
    map_data: Map_Data
    map_data.data = ' '
    in_map_data := false

    for line in strings.split_lines_iterator(&str) {
        if valid_map_row(line) {
            if len(line) >= Max_Map_Width {
               fmt.eprintfln("Level data must be less than %d long per line.", Max_Map_Width)
                return false
            }

            if !in_map_data {
                line_num = 0
                in_map_data = true
                max_len = -1
                map_data = {}
            }

            if max_len < 0 || max_len < len(line) {
                max_len = len(line)
            }

            c_count := 0
            for c in line {
                map_data.data[grid_index(c_count, line_num, Max_Map_Width)] = cast(u8)c
                c_count += 1
            }

            line_num += 1
        } else if len(line) > 0 {
            if strings.starts_with(line, "Author:") {
                map_data.author = line[7:]
            } else if strings.starts_with(line, "Title:") {
                map_data.title = line[6:]
            }
        } else {
            if in_map_data {
                in_map_data = false
                map_data.width = max_len
                map_data.height = line_num
                append(&map_list, map_data)
            }
        }
    }

    if in_map_data {
        map_data.width = max_len
        map_data.height = line_num
        append(&map_list, map_data)
    }

    return true
}

grid_index_xy :: #force_inline proc(x, y, width: int) -> int {
    return x + width * y
}

grid_index_pos :: #force_inline proc(position: Position, width: int) -> int {
    return grid_index(position[0], position[1], width)
}

grid_index :: proc {
    grid_index_xy,
    grid_index_pos
}

new_entity :: proc(g: ^Game_State, type: Entity_Type, position: Position, flags: Entity_Flags_Set = {.Moveable}) -> ^Entity {
    if g.num_entities >= Max_Entities {
        return nil
    }

    e := &g.entities[g.num_entities]
    e.type = type
    e.flags = flags
    e.position = position
    e.id = cast(int)g.num_entities
    e.overlapped_id = -1
    e.enabled = false

    g.entity_map[grid_index(position, Max_Map_Width)] = e.id
    g.num_entities += 1

    if type == .Box {
        g.num_boxes += 1
    } else if type == .Exit {
        g.num_exits += 1
    }


    return e
}

update_exits :: proc(g: ^Game_State) {
    for i in 0..<g.num_entities {
        if g.entities[i].type == .Exit {
            g.entities[i].flags = { .Overlapped } if g.solved else {}
        }
    }
}

init_map :: proc(map_index: int, g: ^Game_State) -> bool{
    g.entities = {}
    g.entity_map = -1
    g.num_moves = 0
    g.num_boxes = 0
    g.num_entities = 0
    g.player = nil

    if map_index >= len(map_list) {
        return false
    }

    if g.map_index != map_index {
        g.map_index = map_index
        clear(&history_states)
    }

    g.map_data = &map_list[map_index]

    for y in 0..<g.map_data.height {
        for x in 0..<g.map_data.width {
            idx := grid_index(x, y, Max_Map_Width)
            switch g.map_data.data[idx] {
                case 'x': new_entity(g, .Exit, { x, y} , {})
                case '.': new_entity(g, .Goal, {x, y}, { .Overlapped })
                case '$': fallthrough
                case 'b': new_entity(g, .Box, {x, y})
                case '@': fallthrough
                case 'p': g.player = new_entity(g, .Player, {x, y})
                case '+': fallthrough
                case 'P': {
                    goal := new_entity(g, .Goal, {x, y}, {.Overlapped})
                    g.player = new_entity(g, .Player, {x, y})
                    g.player.overlapped_id = goal.id
                }
                case '*': fallthrough
                case 'B': {
                    goal := new_entity(g, .Goal, {x, y}, {.Overlapped})
                    box := new_entity(g, .Box, {x, y})
                    box.overlapped_id = goal.id
                }
                case:
            }
        }
    }

    // we store a known playable state
    append(&history_states, g^)
    return true
}

draw_map :: proc(g: ^Game_State) {
    fmt.print("\x1b[2J")

    tdims := terminal_dimensions()

    for y in 0..<g.map_data.height {
        for x in 0..<g.map_data.width {
            idx := grid_index(x, y, Max_Map_Width)
            xx := (tdims[0] / 2) - g.map_data.width + x + 1
            yy := (tdims[1] / 2) - g.map_data.height + y + 1

            // Draw walls:
            if g.map_data.data[idx] == '#' {
                fmt.printf("\x1b[%d;%dH\x1b[48;2;150;41;56m\x1b[38;2;100;100;100m#\x1b[39m\x1b[49m", yy, xx)
            }

            // entities:
            entity_id := g.entity_map[idx]

            if entity_id < 0 do continue

            e := &g.entities[entity_id]

            if e != nil {
                switch e.type {
                    case .Player: {
                        if e.overlapped_id > -1 && g.entities[e.overlapped_id].type == .Goal {
                            fmt.printf("\x1b[%d;%dH\x1b[48;2;205;53;36m\x1b[38;2;128;0;128m@\x1b[39m\x1b[49m", yy, xx)
                        } else {
                            fmt.printf("\x1b[%d;%dH\x1b[38;2;128;0;128m@\x1b[39m\x1b[49m", yy, xx)
                        }
                    }
                    case .Box: {
                        if e.overlapped_id > -1 && g.entities[e.overlapped_id].type == .Goal {
                            fmt.printf("\x1b[%d;%dH\x1b[38;2;200;216;73m\x1b[48;2;78;53;36m%%\x1b[39m\x1b[49m", yy, xx)
                        } else {
                            fmt.printf("\x1b[%d;%dH\x1b[38;2;164;116;73m\x1b[48;2;78;53;36m%%\x1b[39m\x1b[49m", yy, xx)
                        }
                    }
                    case .Goal: fmt.printf("\x1b[%d;%dH\x1b[38;2;255;165;0m!\x1b[39m\x1b[49m", yy, xx)
                    case .Exit: {
                        if g.solved {
                            fmt.printf("\x1b[%d;%dH\x1b[48;2;128;0;128m\x1b[38;2;255;215;0mx\x1b[39m\x1b[49m", yy, xx)
                        }  else {
                            fmt.printf("\x1b[%d;%dH\x1b[48;2;150;41;56m\x1b[38;2;100;100;100m#\x1b[39m\x1b[49m", yy, xx)
                        }
                    }
                }
            }
        }
    }
}

pop_state :: proc() {
    if len(history_states) == 1 {
        current_state = history_states[0]
        return
    }

    current_state = pop(&history_states)
}

do_move :: proc(e: ^Entity, g: ^Game_State, move_dir: Position, force: ^Entity) -> bool {
    move_pos := e.position + move_dir 
    move_index :=  grid_index(move_pos, Max_Map_Width)

    if .Overlapped in e.flags {
        return true
    }

    if .Moveable not_in e.flags {
        return false
    }

    if move_index < 0 || move_index >= Max_Map_Width * Max_Map_Height {
        return false
    }

    if g.map_data.data[move_index] == '#' || (g.map_data.data[move_index] == 'x' && !g.solved) {
        return false
    }

    if e.type == .Box && force.type != .Player {
        return false
    }

    entity_id := g.entity_map[move_index]

    if entity_id >= 0 {
        if !do_move(&g.entities[entity_id], g, move_dir, e) {
            return false
        }
        g.num_pushes += 1
    }

    old_grid_idx := grid_index(e.position, Max_Map_Width)

    // if we've overlapped an entity previously, we set the current pos to that overlapped id,
    // and if we're about to overlap an entity, we store that as the new overlap id
    if e.overlapped_id > -1 {
        g.entities[e.overlapped_id].enabled = false
    }

    g.entity_map[old_grid_idx] = e.overlapped_id
    e.overlapped_id = g.entity_map[move_index]

    if e.overlapped_id > -1 && g.entities[e.overlapped_id].type == .Goal {
        if e.type == .Box {
            g.entities[e.overlapped_id].enabled = true
        }
    }

    e.position = move_pos
    g.entity_map[move_index] = e.id

    return true
}

main :: proc() {
    quit := false
    win := false

    alloc_err := virtual.arena_init_growing(&persistent_arena)

    if alloc_err != nil {
        return
    }

    persistent_allocator = virtual.arena_allocator(&persistent_arena)

    history_states = make([dynamic]Game_State)

    map_ok := load_sok("levels/Mini Cosmos.sok")

    if !map_ok || len(map_list) == 0 {
        fmt.eprintln("Failed to load test map.")
        return
    }

    // TODO: Implement vermin
    // if !vermin.init() {
    //     return
    // }

    init_terminal()

    init_map(0, &current_state)

    fmt.print("\x1b[?1049h\x1b[?25l")

    for !quit {
        draw_map(&current_state)

        input: Input

        process_keys(&input)

        if input.quit {
            quit = true
        }

        move := Position { 0, 0 }

        if input.up {
            move = { 0, -1 }
        } else if input.down {
            move = { 0, 1 }
        } else if input.left {
            move = { -1, 0 }
        } else if input.right {
            move = { 1, 0 }
        }

        if move != { 0, 0 } {
            // store the current state prior to updates, if the move succeeds,
            // store the previous state, otherwise continue.
            temp_state := current_state
            if do_move(current_state.player, &current_state, move, nil) {
                // TODO: Realistically the only state that changes between moves is
                // the move count, and entity state. It would be smart to calculate
                // the deltas between the moves and only store those in the history,
                // instead of the whole struct
                append(&history_states, temp_state)
                current_state.num_moves += 1
            }
        }
    
        if input.reset {
            init_map(current_state.map_index, &current_state)
        }

        if input.undo {
            pop_state()
        }

        update_exits(&current_state)

        all_goals_enabled := true
        for i in 0..<current_state.num_entities {
            if current_state.entities[i].type == .Goal {
                all_goals_enabled &&= current_state.entities[i].enabled
            }
        }

        if all_goals_enabled {
            current_state.solved = true

            if current_state.num_exits == 0 {
                win = true
            }
        } else {
            current_state.solved = false
        }

        if current_state.num_exits > 0 && current_state.player.overlapped_id > -1 {
            if current_state.entities[current_state.player.overlapped_id].type == .Exit {
                win = true
            }
        }

        if win {
            if !init_map(current_state.map_index + 1, &current_state) {
                quit = true
            } else {
                win = false
            }
        }
    }

    // clear all formatting:
    fmt.print("\x1b[39m\x1b[49m\x1b[?25h\x1b[?1049l")

    quit_terminal()
}
