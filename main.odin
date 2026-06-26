// 
// 
// 
// 
package main

import "core:mem"
import "core:strings"
import "core:fmt"
import "core:os"
import "core:bytes"
import "core:io"

Max_Maps :: 16 // or whatever
Position :: distinct [2]int
Max_Entities :: 64
Max_Map_Width :: 80
Max_Map_Height :: 80

Game_State :: struct {
    num_entities: u32,
    num_boxes: u32,
    num_exits: u32,
    entities: [Max_Entities]Entity,
    wall_data: [Max_Map_Width*Max_Map_Height]u8,
    entity_map: [Max_Map_Width*Max_Map_Height]int,
    map_data: ^Map_Data,
    player: ^Entity, // short hand to get into the entity map, we always want to "do move" from the player entity out
    moves: int,
    solved: bool
}

Map_Data :: struct {
    width, height: int,
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
    enabled: bool
}

load_map :: proc(path: string) -> (bool, Map_Data) {
    if !os.exists(path) {
        return false, {}
    }

    f, err := os.open(path)

    if err != nil {
        return false, {}
    }

    data: []byte
    data, err = os.read_entire_file(f, context.allocator)

    if err != nil {
        return false, {}
    }

    defer delete(data)

    str := cast(string)data

    max_len := -1
    line_num := 0
    map_data: Map_Data
    map_data.data = ' '

    for line in strings.split_lines_iterator(&str) {
        if max_len < 0 || max_len < len(line) {
            max_len = len(line)
        }

        if len(line) >= Max_Map_Width {
            fmt.eprintfln("Level data must be less than %d long per line.", Max_Map_Width)
            return false, {}
        }

        c_count := 0
        for c in line {
            map_data.data[grid_index(c_count, line_num, Max_Map_Width)] = cast(u8)c
            c_count += 1
        }

        line_num += 1
    }

    map_data.width = max_len
    map_data.height = line_num

    return true, map_data
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

init_map :: proc(m: ^Map_Data, g: ^Game_State) {
    g.wall_data = 0
    g.entities = {}
    g.entity_map = -1
    g.moves = 0
    g.num_boxes = 0
    g.num_entities = 0

    g.map_data = m

    for y in 0..<m.height {
        for x in 0..<m.width {
            idx := grid_index(x, y, Max_Map_Width)
            switch m.data[idx] {
                case '#': g.wall_data[idx] = '#'
                case 'x': new_entity(g, .Exit, { x, y} , {})
                case '.': new_entity(g, .Goal, {x, y}, { .Overlapped })
                case '$': new_entity(g, .Box, {x, y})
                case '@': g.player = new_entity(g, .Player, {x, y})
                case:
            }
        }
    }
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
            if g.wall_data[idx] == '#' {
                fmt.printf("\x1b[%d;%dH\x1b[48;2;150;41;56m\x1b[38;2;100;100;100m#\x1b[39m\x1b[49m", yy, xx)
            }

            // entities:
            entity_id := g.entity_map[idx]

            if entity_id < 0 do continue

            e := &g.entities[entity_id]

            if e != nil {
                switch e.type {
                    case .Player: fmt.printf("\x1b[%d;%dH\x1b[38;2;128;0;128m@\x1b[39m\x1b[49m", yy, xx)
                    case .Box: fmt.printf("\x1b[%d;%dH\x1b[38;2;164;116;73m\x1b[48;2;78;53;36m%%\x1b[39m\x1b[49m", yy, xx)
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

do_move :: proc(e: ^Entity, g: ^Game_State, x_move: int, y_move: int, f: ^Entity) -> bool {
    move_pos := e.position + { x_move, y_move } 
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

    if g.wall_data[move_index] == '#' || (g.wall_data[move_index] == 'x' && !g.solved) {
        return false
    }

    if e.type == .Box && f.type != .Player {
        return false
    }

    entity_id := g.entity_map[move_index]

    if entity_id >= 0 {
        if !do_move(&g.entities[entity_id], g, x_move, y_move, e) {
            return false
        }
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
        g.entities[e.overlapped_id].enabled = true
    }

    e.position = move_pos
    g.entity_map[move_index] = e.id
    return true
}

main :: proc() {
    state: Game_State
    quit := false
    win := false

    map_ok, test_map := load_map("levels/test.txt")

    if !map_ok {
        fmt.eprintln("Failed to load test map.")
        return
    }

    init_terminal()

    init_map(&test_map, &state)

    fmt.print("\x1b[?1049h\x1b[?25l")

    for !quit {
        draw_map(&state)

        if !process_keys(&state) {
            quit = true
        }

        update_exits(&state)

        all_goals_enabled := true
        for i in 0..<state.num_entities {
            if state.entities[i].type == .Goal {
                all_goals_enabled &&= state.entities[i].enabled
            }
        }

        if all_goals_enabled {
            state.solved = true

            if state.num_exits == 0 {
                win = true
                quit = true
            }
        } else {
            state.solved = false
        }

        if state.num_exits > 0 && state.player.overlapped_id > -1 {
            if state.entities[state.player.overlapped_id].type == .Exit {
                win = true
                quit = true
            }
        }
    }

    // clear all formatting:
    fmt.print("\x1b[39m\x1b[49m")
    fmt.print("\x1b[?1049l")

    quit_terminal()

    if win {
        fmt.print("Winner!")
    }
}
