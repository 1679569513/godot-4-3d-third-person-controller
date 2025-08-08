# =============================================
# CameraController - 3D相机控制系统
# 
# 功能：
# 1. 支持过肩视角/第三人称视角切换
# 2. 鼠标/手柄双输入支持
# 3. 智能碰撞检测与视角避障
# 4. 可配置的灵敏度与视角限制
# =============================================
class_name CameraController
extends Node3D

## 相机视角模式枚举
## @enum OVER_SHOULDER: 过肩视角
## @enum THIRD_PERSON: 第三人称视角
enum CAMERA_PIVOT { OVER_SHOULDER, THIRD_PERSON }

#region 导出变量 (编辑器可配置)
@export_node_path var player_path : NodePath # 目标玩家节点路径
@export var invert_mouse_y := false # 反转Y轴鼠标移动
@export_range(0.0, 1.0) var mouse_sensitivity := 0.25 # 鼠标灵敏度 
@export_range(0.0, 8.0) var joystick_sensitivity := 2.0  # 手柄灵敏度
@export var tilt_upper_limit := deg_to_rad(-60.0) # 最大上仰角度 (单位：弧度)
@export var tilt_lower_limit := deg_to_rad(60.0) # 最大下俯角度 (单位：弧度)
#endregion

#region 子节点引用
@onready var camera: Camera3D = $PlayerCamera # 主相机节点
@onready var _over_shoulder_pivot: Node3D = $CameraOverShoulderPivot # 过肩视角枢轴点
@onready var _camera_spring_arm: SpringArm3D = $CameraSpringArm # 弹簧臂组件
@onready var _third_person_pivot: Node3D = $CameraSpringArm/CameraThirdPersonPivot # 第三人称枢轴点
@onready var _camera_raycast: RayCast3D = $PlayerCamera/CameraRayCast # 相机碰撞检测射线
#endregion

#region 运行时变量
var _aim_target : Vector3 # 当前瞄准目标点
var _aim_collider: Node # 射线碰撞到的物体
var _pivot: Node3D # 当前使用的视角枢轴点
var _current_pivot_type: CAMERA_PIVOT # 当前视角模式
var _rotation_input: float # 水平旋转输入值
var _tilt_input: float # 垂直倾斜输入值
var _mouse_input := false # 是否使用鼠标输入
var _offset: Vector3 # 相机偏移量
var _anchor: CharacterBody3D # 锚点角色
var _euler_rotation: Vector3 # 当前欧拉角旋转
#endregion

## 处理未捕获的输入事件
func _unhandled_input(event: InputEvent) -> void:
    # 检测是否为鼠标移动输入且鼠标模式为捕获状态
	_mouse_input = event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	if _mouse_input:
		_rotation_input = -event.relative.x * mouse_sensitivity
		_tilt_input = -event.relative.y * mouse_sensitivity

## 每帧处理相机逻辑
func _process(delta: float) -> void:
	if not _anchor:
		return
    # 处理手柄输入
	_rotation_input += Input.get_action_raw_strength("camera_left") - Input.get_action_raw_strength("camera_right")
	_tilt_input += Input.get_action_raw_strength("camera_up") - Input.get_action_raw_strength("camera_down")

    # 处理Y轴反转
	if invert_mouse_y:
		_tilt_input *= -1

    # 处理射线碰撞检测
	if _camera_raycast.is_colliding():
		_aim_target = _camera_raycast.get_collision_point()
		_aim_collider = _camera_raycast.get_collider()
	else:
		_aim_target = _camera_raycast.global_transform * _camera_raycast.target_position
		_aim_collider = null

	# Set camera controller to current ground level for the character
    # 计算目标位置（角色位置+预设偏移量）
	var target_position := _anchor.global_position + _offset
	target_position.y = lerp(global_position.y, _anchor._ground_height, 0.1)
	global_position = target_position

	# Rotates camera using euler rotation
    # 更新欧拉角旋转（基于输入和时间增量）
	_euler_rotation.x += _tilt_input * delta
	_euler_rotation.x = clamp(_euler_rotation.x, tilt_lower_limit, tilt_upper_limit)
	_euler_rotation.y += _rotation_input * delta

	transform.basis = Basis.from_euler(_euler_rotation)

    # 同步相机与枢轴点的全局变换
	camera.global_transform = _pivot.global_transform
	camera.rotation.z = 0 # 消除Z轴旋转（防止相机倾斜）

	_rotation_input = 0.0
	_tilt_input = 0.0

## 初始化相机控制器
##
## @param anchor: 要跟随的CharacterBody3D角色节点
## @note 必须在场景加载完成后调用此方法
func setup(anchor: CharacterBody3D) -> void:
	_anchor = anchor
	global_transform = _anchor.global_transform # 同步初始变换到锚点位置
	_offset = global_transform.origin - anchor.global_transform.origin# 计算初始偏移量（相机与角色的相对位置）
	set_pivot(CAMERA_PIVOT.THIRD_PERSON)
    # 平滑过渡相机位置到枢轴点位置（10%插值）
	camera.global_transform = camera.global_transform.interpolate_with(_pivot.global_transform, 0.1)
	_camera_spring_arm.add_excluded_object(_anchor.get_rid()) # 将角色从弹簧臂碰撞检测中排除（防止角色自身遮挡相机）
	_camera_raycast.add_exception_rid(_anchor.get_rid())  # 将角色从射线检测中排除（防止角色自身被误检测）

## 设置相机视角枢轴点类型
##
## @param pivot_type: 要切换的视角模式(CAMERA_PIVOT枚举)
## @note 此方法会立即切换相机视角，不会产生过渡动画
func set_pivot(pivot_type: CAMERA_PIVOT) -> void:
	if pivot_type == _current_pivot_type:
		return

	match(pivot_type):
		CAMERA_PIVOT.OVER_SHOULDER:
			_over_shoulder_pivot.look_at(_aim_target)
			_pivot = _over_shoulder_pivot # 切换枢轴点引用
		CAMERA_PIVOT.THIRD_PERSON:
			_pivot = _third_person_pivot

	_current_pivot_type = pivot_type

## 获取当前瞄准目标的世界坐标
##
## @return: Vector3 返回当前射线检测命中的目标点世界坐标
## @note: 当射线未命中任何物体时，返回的是射线末端的默认位置
func get_aim_target() -> Vector3:
	return _aim_target 

## 获取当前射线命中的碰撞体
##
## @return: Node 返回有效的碰撞体节点引用，未命中或节点无效时返回null
## @warning: 返回的节点可能在下帧被销毁，使用前应再次验证有效性
func get_aim_collider() -> Node:
	if is_instance_valid(_aim_collider):
		return _aim_collider
	else:
		return null
