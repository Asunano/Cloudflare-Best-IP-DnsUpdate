// 预编译发布版隐藏控制台窗口（Windows）。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    cfopt_gui_lib::run()
}
