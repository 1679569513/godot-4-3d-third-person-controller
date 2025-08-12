class_name GrenadeLauncher
extends Node3D

const GRENADE_SCENE := preload("res://Player/Grenade.tscn")

@export var min_throw_distance := 7.0
@export var max_throw_distance := 16.0
@export var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var from_look_position := Vector3.ZERO
@onready var throw_direction := Vector3.ZERO

@onready var _snap_mesh: Node3D = %SnapMesh
@onready var _raycast: ShapeCast3D = %ShapeCast3D
@onready var _launch_point: Marker3D = %LaunchPoint
@onready var _trail_mesh_instance: MeshInstance3D = %TrailMeshInstance

var _throw_velocity := Vector3.ZERO
var _time_to_land := 0.0


# 节点准备就绪回调函数
# 功能：初始化节点时控制物理处理的启用状态
# 设计目的：避免在编辑器模式下消耗不必要的物理计算资源
func _ready() -> void:
	if Engine.is_editor_hint(): # 当节点在Godot编辑器中显示时（非游戏运行时）  防止编辑器预览时产生不必要的物理计算和性能消耗
		set_physics_process(false)

## 在Godot引擎中，当调用set_physics_process(false)后，‌节点的_physics_process回调将完全停止执行‌
## set_physics_process(false)  # 停止物理帧回调
## set_process(false)         # 停止常规帧回调（两者独立控制）
## 典型应用场景
## |场景类型|代码示例|作用|
## |---|---|---|
## |对象死亡|health=0; set_physics_process(false)|避免死亡后持续检测碰撞|
## |编辑器优化|if Engine.editor_hint: set_physics_process(false)|减少编辑模式资源消耗|
## |暂停游戏|get_tree().paused=true（全局暂停|替代方案|

func _physics_process(_delta: float) -> void:
	if visible:
		_update_throw_velocity() # 更新投掷物初速度参数
		_draw_throw_path()  # 绘制预测轨迹线（视觉反馈）

## 投掷手榴弹主函数
## @return bool 投掷是否成功执行
func throw_grenade() -> bool:
	if not visible:
		return false

	var grenade: CharacterBody3D = GRENADE_SCENE.instantiate() # 实例化手榴弹预制体
	get_parent().add_child(grenade)
	grenade.global_position = _launch_point.global_position
	grenade.throw(_throw_velocity)
	PhysicsServer3D.body_add_collision_exception(get_parent().get_rid(), grenade.get_rid()) # 物理碰撞例外设置（避免与投掷者碰撞）
	return true


## 更新手榴弹投掷初速度计算
## 实现抛物线物理模拟和自动瞄准修正功能
func _update_throw_velocity() -> void:
	var camera := get_viewport().get_camera_3d() # 获取当前3D摄像机参照系
	var up_ratio: float = clamp(max(camera.rotation.x + 0.5, -0.4) * 2, 0.0, 1.0)

	# var throw_direction := camera.quaternion * Vector3.FORWARD
	# If the player's not aiming, the camera's far behind the character, so we increase the ray's
	# length based on how far behind the camera is compared to the character.
	#‌# 数学表达式‌
	## result = a + (b - a) * t
    ## up_ratio弧度 映射到0-1区间
	var base_throw_distance: float = lerp(min_throw_distance, max_throw_distance, up_ratio)  # 计算基础投掷距离（根据俯仰角在最小/最大距离间插值）
	# var camera_forward_distance := camera.global_position.project(throw_direction).distance_to(_launch_point.global_position.project(throw_direction))
	var throw_distance := base_throw_distance #+ camera_forward_distance  
    # global_camera_look_position 摄像机最终注视位置 from_look_position 摄像机初始注视点  throw_direction：标准化投掷方向向量 throw_distance：投掷物飞行距离标量值
	var global_camera_look_position := from_look_position + throw_direction * throw_distance
	_raycast.target_position = global_camera_look_position - _raycast.global_position # 射线发射器

	#region 目标锁定检测系统
	# Snap grenade land position to an enemy the player's aiming at, if applicable
	var to_target := _raycast.target_position

	# 射线碰撞检测处理
	if _raycast.get_collision_count() != 0 :
		var collider := _raycast.get_collider(0)
		var has_target: bool = collider and collider.is_in_group("targeteables")
		_snap_mesh.visible = has_target
		if has_target: # 检查碰撞体是否属于可锁定目标组
			to_target = collider.global_position - _launch_point.global_position
			_snap_mesh.global_position = _launch_point.global_position + to_target
			_snap_mesh.look_at(_launch_point.global_position)
	else:
		_snap_mesh.visible = false
	#endregion

	#region 弹道物理计算系统
	# Calculate the initial velocity the grenade needs based on where we want it to land and how
	# high the curve should go.
	var peak_height: float = max(to_target.y + 0.25, _launch_point.position.y + 0.25) # 计算抛物线顶点高度（确保高于发射点和目标点）

	var motion_up := peak_height
	# t= v/g  v₀ = √(2gh)
	var time_going_up := sqrt(2.0 * motion_up / gravity)

	var motion_down := to_target.y - peak_height
	var time_going_down := sqrt(-2.0 * motion_down / gravity)

	_time_to_land = time_going_up + time_going_down

	# 水平面(XZ平面)位置计算
	var target_position_xz_plane := Vector3(to_target.x, 0.0, to_target.z)
	var start_position_xz_plane := Vector3(_launch_point.position.x, 0.0, _launch_point.position.z)

	var forward_velocity := (target_position_xz_plane - start_position_xz_plane) / _time_to_land  计算水平初速度
	var velocity_up := sqrt(2.0 * gravity * motion_up) # 计算垂直初速度（v=√(2gh)）

	# Caching the found initial_velocity vector so we can use it on the throw() function
	_throw_velocity = Vector3.UP * velocity_up + forward_velocity # 合成最终投掷速度向量


# ======================================================
# 投掷物轨迹可视化工具 (Godot 4.4)
# 功能：通过三角面片生成带纹理的抛物线轨迹网格
# ======================================================
func _draw_throw_path() -> void:
	const TIME_STEP := 0.05
	const TRAIL_WIDTH := 0.25

	var forward_direction = Vector3(_throw_velocity.x, 0.0, _throw_velocity.z).normalized()
	var left_direction := Vector3.UP.cross(forward_direction) # 通过叉积获得左方向（垂直于前进方向和上方向）
	# 计算轨迹带左右偏移量
	var offset_left = left_direction * TRAIL_WIDTH / 2.0
	var offset_right = -left_direction * TRAIL_WIDTH / 2.0

	# 网格构建工具初始化
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES) # 三角形为基本单元进行渲染

	var end_time := _time_to_land + 0.5 # 落地时间+缓冲时间
	var point_previous = Vector3.ZERO # 上一帧位置
	var time_current := 0.0
	# We'll create 2 triangles on each iteration, representing the quad of one
	# section of the path
	while time_current < end_time:
		time_current += TIME_STEP
		# 抛物线运动公式：s = v0*t + 0.5*a*t²
		var point_current := _throw_velocity * time_current + Vector3.DOWN * gravity * 0.5 * time_current * time_current

		 # 计算当前段的四个顶点（形成四边形）
		# Our point coordinates are at the center of the path, so we need to calculate vertices
		var trail_point_left_end = point_current + offset_left
		var trail_point_right_end = point_current + offset_right
		var trail_point_left_start = point_previous + offset_left
		var trail_point_right_start = point_previous + offset_right

		# UV纹理坐标计算（0-1范围）
		# UV position goes from 0 to 1, so we normalize the current iteration
		# to get the progress in the UV texture
		var uv_progress_end = time_current/end_time
		var uv_progress_start = uv_progress_end - (TIME_STEP/end_time)

		# UV坐标映射（左轨对应纹理上部，右轨对应下部）
		# Left side on the UV texture is at the top of the texture
		# (Vector2(0,1), or Vector2.DOWN). Right side on the UV texture is at
		# the bottom.
		# Vector2.RIGHT (1,0) 代表纹理右边缘
		# Vector2.DOWN (0,1) 代表纹理底部
		# 纹理空间：
		# (0,1) +-----------+ (1,1)  ← 左轨UV
		#        |           |
		#        |           |
		# (0,0) +-----------+ (1,0)  ← 右轨UV

		var uv_value_right_start = (Vector2.RIGHT * uv_progress_start)
		var uv_value_right_end = (Vector2.RIGHT * uv_progress_end)
		var uv_value_left_start = Vector2.DOWN + uv_value_right_start
		var uv_value_left_end = Vector2.DOWN + uv_value_right_end

		point_previous = point_current

		# Both triangles need to be drawn in the same orientation (Godot uses
		# clockwise orientation to determine the face normal)

		# Godot默认启用背面剔除（Backface Culling），只有顺时针定义的三角形才会被渲染。若顺序错误会导致面片不可见。
		# 当顶点按‌顺时针（CW）顺序‌连接时，定义三角形‌正面‌
		# 当顶点按‌逆时针（CCW）顺序‌连接时，定义三角形‌背面‌
		# 构建两个三角形组成四边形面片（顺时针顶点顺序）
		# 三角形1：右终点 -> 左起点 -> 左终点 （待确认）
		# Draw first triangle
		st.set_uv(uv_value_right_end)
		st.add_vertex(trail_point_right_end)
		st.set_uv(uv_value_left_start)
		st.add_vertex(trail_point_left_start)
		st.set_uv(uv_value_left_end)
		st.add_vertex(trail_point_left_end)

		# 三角形2：右起点 -> 左起点 -> 右终点
		# Draw second triangle
		st.set_uv(uv_value_right_start)
		st.add_vertex(trail_point_right_start)
		st.set_uv(uv_value_left_start)
		st.add_vertex(trail_point_left_start)
		st.set_uv(uv_value_right_end)
		st.add_vertex(trail_point_right_end)

	st.generate_normals()
	_trail_mesh_instance.mesh = st.commit()
