// 
// 
// 
// 
package main

import "core:mem"
import "core:fmt"
import win32 "core:sys/windows"

Position :: distinct [2]int
Max_Entities :: 64
Max_Map_Width :: 80
Max_Map_Height :: 20

Game_State :: struct {
    num_entities: u32,
    num_boxes: u32,
    entities: [Max_Entities]Entity,
    wall_data: [Max_Map_Width*Max_Map_Height]u8,
    entity_map: [Max_Map_Width*Max_Map_Height]int,
    map_data: ^Map_Data,
    player: ^Entity, // short hand to get into the entity map, we always want to "do move" from the player entity out
    moves: int
}

Map_Data :: struct {
    width, height: int,
    data: []u8
}

Entity_Type :: enum {
    Player,
    Box,
    Goal
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

// #####
// # ! #
// # % #
// # @ #
// #####

Test_Map := Map_Data {
    width = 7,
    height = 7,
    data = { '#', '#', '#', '#', '#', '#', '#',
             '#', ' ', '!', ' ', ' ', ' ', '#',
             '#', ' ', ' ', ' ', ' ', ' ', '#',
             '#', ' ', '%', '%', ' ', ' ', '#', 
             '#', ' ', '%', ' ', ' ', ' ', '#',
             '#', ' ', '@', ' ', ' ', ' ', '#',
             '#', '#', '#', '#', '#', '#', '#'}
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

    g.entity_map[grid_index(position, g.map_data.width)] = e.id
    g.num_entities += 1

    if type == .Box {
        g.num_boxes += 1
    }


    return e
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
            idx := grid_index(x, y, m.width)
            switch m.data[idx] {
                case '#': g.wall_data[idx] = '#'
                case '!': new_entity(g, .Goal, {x, y}, { .Overlapped })
                case '%': new_entity(g, .Box, {x, y})
                case '@': g.player = new_entity(g, .Player, {x, y})
                case:
            }
        }
    }
}

draw_map :: proc(g: ^Game_State) {
    fmt.print("\x1b[2J")

    for y in 0..<g.map_data.width {
        for x in 0..<g.map_data.height {
            idx := grid_index(x, y, g.map_data.width)
            yy := y + 1
            xx := x + 1

            // Draw walls:
            if g.wall_data[idx] == '#' {
                fmt.printf("\x1b[%d;%dH#", yy, xx)
            }

            // entities:
            entity_id := g.entity_map[idx]

            if entity_id < 0 do continue

            e := &g.entities[entity_id]

            if e != nil {
                switch e.type {
                    case .Player: fmt.printf("\x1b[%d;%dH@", yy, xx)
                    case .Box: fmt.printf("\x1b[%d;%dH%%", yy, xx)
                    case .Goal: fmt.printf("\x1b[%d;%dH!", yy, xx)
                }
            }
        }
    }
}

do_move :: proc(e: ^Entity, g: ^Game_State, x_move: int, y_move: int) -> bool {
    move_pos := e.position + { x_move, y_move } 
    move_index :=  grid_index(move_pos, g.map_data.width)

    if .Overlapped in e.flags {
        return true
    }

    if .Moveable not_in e.flags {
        return false
    }

    if move_index < 0 || move_index >= g.map_data.width * g.map_data.height {
        return false
    }

    if g.wall_data[move_index] == '#' {
        return false
    }

    entity_id := g.entity_map[move_index]

    if entity_id >= 0 {
        if !do_move(&g.entities[entity_id], g, x_move, y_move) {
            return false
        }
    }

    old_grid_idx := grid_index(e.position, g.map_data.width)

    // if we've overlapped an entity previously, we set the current pos to that overlapped id,
    // and if we're about to overlap an entity, we store that as the new overlap id
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
    std_in_handle := win32.GetStdHandle(win32.STD_INPUT_HANDLE)
    std_out_handle := win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)

    console_mode: u32

    win32.GetConsoleMode(std_out_handle, &console_mode)
    win32.SetConsoleMode(std_out_handle, console_mode | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING)

    state: Game_State
    quit := false
    win := false

    init_map(&Test_Map, &state)

    fmt.print("\x1b[?1049h\x1b[?25l")
    input_record_buf: [32]win32.INPUT_RECORD
    input_event_count: u32

    for !quit {
        draw_map(&state)

        win32.ReadConsoleInputW(std_in_handle, &input_record_buf[0], len(input_record_buf), &input_event_count)

        if input_event_count > 0 {
            for i in 0..<input_event_count {
                #partial switch input_record_buf[i].EventType {
                    case .KEY_EVENT:
                        key_event := input_record_buf[i].Event.KeyEvent

                        if key_event.bKeyDown == false do continue
                        if key_event.wRepeatCount > 1 do continue

                        switch key_event.wVirtualKeyCode {
                            case win32.VK_ESCAPE: quit = true
                            case win32.VK_UP: if do_move(state.player, &state, 0, -1) do state.moves += 1
                            case win32.VK_DOWN: if do_move(state.player, &state, 0, 1) do state.moves += 1
                            case win32.VK_LEFT: if do_move(state.player, &state, -1, 0) do state.moves += 1
                            case win32.VK_RIGHT: if do_move(state.player, &state, 1, 0) do state.moves += 1
                            case win32.VK_R: init_map(&Test_Map, &state)
                            case:
                        }
                    case:
                }
            }
        }

        all_goals_enabled := true
        for i in 0..<state.num_entities {
            if state.entities[i].type == .Goal {
                all_goals_enabled &&= state.entities[i].enabled
            }
        }

        if all_goals_enabled {
            win = true
            quit = true
        }
    }

    fmt.print("\x1b[?1049l")
    win32.SetConsoleMode(std_out_handle, console_mode)

    if win {
        fmt.println("Winner!")
    }
}