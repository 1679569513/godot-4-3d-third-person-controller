class_name Player
extends CharacterBody3D

signal weapon_switched(weapon_name: String) # 玩家武器切换信号

# 预加载资源
const BULLET_SCENE := preload("Bullet.tscn") # 子弹场景资源
const COIN_SCENE := preload("Coin/Coin.tscn")  # 硬币收集物资源

## 武器类型枚举
## @value DEFAULT: 默认枪械武器
## @value GRENADE: 榴弹发射器
enum WEAPON_TYPE { DEFAULT, GRENADE }

#region 导出变量 - 移动参数
## Character maximum run speed on the ground.
@export var move_speed := 8.0 # 地面最大移动速度(米/秒)
## Speed of shot bullets.
@export var bullet_speed := 10.0 # 子弹飞行速度系数
## Forward impulse after a melee attack.
@export var attack_impulse := 10.0 # 近战攻击后前冲力度
## Movement acceleration (how fast character achieve maximum speed)
@export var acceleration := 4.0 # 移动加速度(影响达到最大速度的快慢)
## Jump impulse
@export var jump_initial_impulse := 12.0 # 基础跳跃初速度
## Jump impulse when player keeps pressing jump
@export var jump_additional_force := 4.5 # 长按跳跃时的持续附加力
## Player model rotation speed
@export var rotation_speed := 12.0 # 角色模型旋转速度(度/秒)
## Minimum horizontal speed on the ground. This controls when the character's animation tree changes
## between the idle and running states.
@export var stopping_speed := 1.0 # 停止判定速度阈值(低于此值切换为站立动画)
## Max throwback force after player takes a hit
@export var max_throwback_force := 15.0 # 受击时最大击退力度
#endregion

#region 导出变量 - 战斗参数
## Projectile cooldown
@export var shoot_cooldown := 0.5 # 射击冷却时间(秒)
## Grenade cooldown
@export var grenade_cooldown := 0.5 # 榴弹冷却时间(秒) 
#endregion

#region 节点引用
@onready var _rotation_root: Node3D = $CharacterRotationRoot # 角色旋转根节点(用于分离模型旋转与碰撞体)
@onready var _camera_controller: CameraController = $CameraController # 摄像机控制器(处理视角控制逻辑)
@onready var _attack_animation_player: AnimationPlayer = $CharacterRotationRoot/MeleeAnchor/AnimationPlayer # 近战攻击动画播放器
@onready var _ground_shapecast: ShapeCast3D = $GroundShapeCast # 地面检测形状投射器
@onready var _grenade_aim_controller: GrenadeLauncher = $GrenadeLauncher # 榴弹发射控制器
@onready var _character_skin: CharacterSkin = $CharacterRotationRoot/CharacterSkin # 角色皮肤控制器(处理动画混合等)
@onready var _ui_aim_recticle: ColorRect = %AimRecticle # UI瞄准准星
@onready var _ui_coins_container: HBoxContainer = %CoinsContainer # 硬币计数UI容器
@onready var _step_sound: AudioStreamPlayer3D = $StepSound # 脚步声效播放器
@onready var _landing_sound: AudioStreamPlayer3D = $LandingSound # 落地声效播放器
#endregion

#region 运行时变量
@onready var _equipped_weapon: WEAPON_TYPE = WEAPON_TYPE.DEFAULT # 当前装备武器类型
@onready var _move_direction := Vector3.ZERO # 标准化移动方向向量
@onready var _last_strong_direction := Vector3.FORWARD # 最后有效移动方向(用于保持面朝方向)
@onready var _gravity: float = -30.0 # 重力加速度(米/秒²)
@onready var _ground_height: float = 0.0 # 地面高度基准值
@onready var _start_position := global_transform.origin # 初始重生位置
@onready var _coins := 0 当前硬币收集数量
@onready var _is_on_floor_buffer := false # 地面检测缓冲(防止快速切换状态)

@onready var _shoot_cooldown_tick := shoot_cooldown # 射击冷却计时器
@onready var _grenade_cooldown_tick := grenade_cooldown # 榴弹冷却计时器


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED # 鼠标模式设置为捕获模式（游戏内隐藏鼠标指针）
	_camera_controller.setup(self) # 初始化摄像机控制器，传入玩家节点引用
	_grenade_aim_controller.visible = false # 默认隐藏榴弹发射器的视觉组件
	weapon_switched.emit(WEAPON_TYPE.keys()[0]) # 发射武器切换信号，传递默认武器名称（枚举转字符串）c

    # 输入动作动态注册检查（兼容性处理）
    # 当项目缺少必需输入动作时自动注册基础控制方案
	# When copying this character to a new project, the project may lack required input actions.
	# In that case, we register input actions for the user at runtime.
	if not InputMap.has_action("move_left"):
		_register_input_actions()
	# 连接角色动画步事件到脚步声播放方法
    # 使用Callable绑定确保类型安全
	_character_skin.stepped.connect(play_foot_step_sound)


func _physics_process(delta: float) -> void:
	# Calculate ground height for camera controller
    # region 地面高度计算
    # 通过ShapeCast检测获取地面高度（用于摄像机高度调整）
	if _ground_shapecast.get_collision_count() > 0:
        # 遍历所有碰撞结果取最高点作为地面基准
		for collision_result in _ground_shapecast.collision_result:
			_ground_height = max(_ground_height, collision_result.point.y)
	else:
        # 无碰撞时使用预设目标位置作为地面高度
		_ground_height = global_position.y + _ground_shapecast.target_position.y
	if global_position.y < _ground_height:
		_ground_height = global_position.y

	# Swap weapons
    # 防止角色穿地时的地面高度错误
	if Input.is_action_just_pressed("swap_weapons"): 
        # 切换武器枚举状态（DEFAULT <-> GRENADE）
		_equipped_weapon = WEAPON_TYPE.DEFAULT if _equipped_weapon == WEAPON_TYPE.GRENADE else WEAPON_TYPE.GRENADE
		_grenade_aim_controller.visible = _equipped_weapon == WEAPON_TYPE.GRENADE  # 更新榴弹发射器可见性
		weapon_switched.emit(WEAPON_TYPE.keys()[_equipped_weapon]) # 发射武器切换信号（传递当前武器名称）
    #endregion

    #region 输入状态检测
	# Get input and movement state
	var is_attacking := Input.is_action_pressed("attack") and not _attack_animation_player.is_playing() # 攻击状态（按住攻击键且不在攻击动画中）
	var is_just_attacking := Input.is_action_just_pressed("attack") # 瞬时攻击触发（攻击键刚按下）
	var is_just_jumping := Input.is_action_just_pressed("jump") and is_on_floor()  # 跳跃触发（在地面且跳跃键刚按下）
	var is_aiming := Input.is_action_pressed("aim") and is_on_floor()  # 瞄准状态（按住瞄准键且在地面）
	var is_air_boosting := Input.is_action_pressed("jump") and not is_on_floor() and velocity.y > 0.0 # 空中跳跃加速（跳跃键按住且上升阶段）
	var is_just_on_floor := is_on_floor() and not _is_on_floor_buffer  # 刚落地检测（当前帧刚接触地面）

    # 更新地面状态缓冲（用于下一帧检测）
	_is_on_floor_buffer = is_on_floor()
     # 获取基于摄像机朝向的输入方向
	_move_direction = _get_camera_oriented_input()
    #endregion

	#region 角色方向控制
	# 保存最后有效移动方向（防止快速转向）
	# 阈值0.2避免微小输入导致角色抖动
	# To not orient quickly to the last input, we save a last strong direction,
	# this also ensures a good normalized value for the rotation basis.
	if _move_direction.length() > 0.2:
		_last_strong_direction = _move_direction.normalized()
	# 瞄准状态下强制使用摄像机后方方向
	if is_aiming:
		_last_strong_direction = (_camera_controller.global_transform.basis * Vector3.BACK).normalized()

	_orient_character_to_direction(_last_strong_direction, delta) # 平滑转向目标方向（delta用于帧率无关插值）
	#endregion
	
	#region 速度计算与处理
	# 临时保存Y轴速度（重力相关）
	# We separate out the y velocity to not interpolate on the gravity
	var y_velocity := velocity.y 
	velocity.y = 0.0  # 清零Y轴用于水平移动计算
	velocity = velocity.lerp(_move_direction * move_speed, acceleration * delta) # 水平速度插值（实现加速/减速效果）
	if _move_direction.length() == 0 and velocity.length() < stopping_speed: # 停止状态检测
		velocity = Vector3.ZERO
	velocity.y = y_velocity
	#endregion

	#region 相机 瞄准状态UI控制
	# Set aiming camera and UI
	if is_aiming:
		_camera_controller.set_pivot(_camera_controller.CAMERA_PIVOT.OVER_SHOULDER)
		_grenade_aim_controller.throw_direction = _camera_controller.camera.quaternion * Vector3.FORWARD
		_grenade_aim_controller.from_look_position = _camera_controller.camera.global_position
		_ui_aim_recticle.visible = true # 显示瞄准UI
	else:
		_camera_controller.set_pivot(_camera_controller.CAMERA_PIVOT.THIRD_PERSON)
		_grenade_aim_controller.throw_direction = _last_strong_direction
		_grenade_aim_controller.from_look_position = global_position
		_ui_aim_recticle.visible = false
	#endregion

	# Update attack state and position

    #region  攻击行为处理模块
	_shoot_cooldown_tick += delta # 武器冷却计时器更新（每帧累加delta时间）
	_grenade_cooldown_tick += delta

	if is_attacking:
		match _equipped_weapon:
			WEAPON_TYPE.DEFAULT:
				if is_aiming and is_on_floor():  # 瞄准 is_on_floor作用不明
					if _shoot_cooldown_tick > shoot_cooldown:
						_shoot_cooldown_tick = 0.0
						shoot()  # 执行射击逻辑
				elif is_just_attacking:
					attack() # 执行近战攻击逻辑
			WEAPON_TYPE.GRENADE:
				if _grenade_cooldown_tick > grenade_cooldown:
					_grenade_cooldown_tick = 0.0
					_grenade_aim_controller.throw_grenade()  # 执行投掷逻辑

	velocity.y += _gravity * delta

    # 跳跃系统处理
	if is_just_jumping:
		velocity.y += jump_initial_impulse
	elif is_air_boosting:
		velocity.y += jump_additional_force * delta

	# 角色动画状态机 
	# Set character animation
	if is_just_jumping:
		_character_skin.jump() # 触发跳跃动画
	elif not is_on_floor() and velocity.y < 0:
		_character_skin.fall() # 下落状态动画
	elif is_on_floor():
		var xz_velocity := Vector3(velocity.x, 0, velocity.z) # 计算水平面速度
		if xz_velocity.length() > stopping_speed:
			_character_skin.set_moving(true)
			_character_skin.set_moving_speed(inverse_lerp(0.0, move_speed, xz_velocity.length()))
		else:
			_character_skin.set_moving(false)

	if is_just_on_floor:
		_landing_sound.play() # 落地音效触发

	var position_before := global_position
	move_and_slide()
	var position_after := global_position

	# If velocity is not 0 but the difference of positions after move_and_slide is,
	# character might be stuck somewhere!
	var delta_position := position_after - position_before
	var epsilon := 0.001
	if delta_position.length() < epsilon and velocity.length() > epsilon:
		global_position += get_wall_normal() * 0.1


func attack() -> void:
	_attack_animation_player.play("Attack")
	_character_skin.punch()
	velocity = _rotation_root.transform.basis * Vector3.BACK * attack_impulse


func shoot() -> void:
	var bullet := BULLET_SCENE.instantiate()
	bullet.shooter = self
	var origin := global_position + Vector3.UP
	var aim_target := _camera_controller.get_aim_target()
	var aim_direction := (aim_target - origin).normalized()
	bullet.velocity = aim_direction * bullet_speed   # 设置初速度
	bullet.distance_limit = 14.0
	get_parent().add_child(bullet) # 将子弹添加到场景树（挂载到父节点）
	bullet.global_position = origin


func reset_position() -> void:
	transform.origin = _start_position

# 金币收集功能
func collect_coin() -> void:
	_coins += 1
	_ui_coins_container.update_coins_amount(_coins)


func lose_coins() -> void:
	var lost_coins: int = min(_coins, 5)
	_coins -= lost_coins
	for i in lost_coins:
		var coin := COIN_SCENE.instantiate()
		get_parent().add_child(coin)
		coin.global_position = global_position
		coin.spawn(1.5)  # 触发金币弹出动画
	_ui_coins_container.update_coins_amount(_coins) # 更新UI显示（必须在主线程操作）



# 获取基于相机朝向的输入向量
# 功能：将2D输入向量转换为3D世界空间向量，并考虑相机旋转和动画状态
func _get_camera_oriented_input() -> Vector3:
	if _attack_animation_player.is_playing(): # 攻击动画播放时锁定移动输入（防止动画穿帮）
		return Vector3.ZERO

	var raw_input := Input.get_vector("move_left", "move_right", "move_up", "move_down") # 获取原始2D输入向量（标准化到[-1,1]范围）

	var input := Vector3.ZERO
	# This is to ensure that diagonal input isn't stronger than axis aligned input
	input.x = -raw_input.x * sqrt(1.0 - raw_input.y * raw_input.y / 2.0)
	input.z = -raw_input.y * sqrt(1.0 - raw_input.x * raw_input.x / 2.0)

	input = _camera_controller.global_transform.basis * input
	input.y = 0.0
	return input


func play_foot_step_sound() -> void:
	_step_sound.pitch_scale = randfn(1.2, 0.2)
	_step_sound.play()

# 角色受击处理函数
func damage(_impact_point: Vector3, force: Vector3) -> void:
	# Always throws character up
	force.y = abs(force.y) # 强制垂直方向为正（确保角色总是被击飞向上）
	velocity = force.limit_length(max_throwback_force)
	lose_coins()


# 角色朝向控制函数
# 功能：平滑旋转模型使其面向移动方向
# 参数：
#   direction: Vector3 - 目标方向向量（世界坐标系，需标准化）
#   delta: float - 帧间隔时间（用于平滑插值）
func _orient_character_to_direction(direction: Vector3, delta: float) -> void:
	var left_axis := Vector3.UP.cross(direction)
	var rotation_basis := Basis(left_axis, Vector3.UP, direction).get_rotation_quaternion()
	var model_scale := _rotation_root.transform.basis.get_scale()
	_rotation_root.transform.basis = Basis(_rotation_root.transform.basis.get_rotation_quaternion().slerp(rotation_basis, delta * rotation_speed)).scaled(
		model_scale
	)


## Used to register required input actions when copying this character to a different project.
func _register_input_actions() -> void:
	const INPUT_ACTIONS := {
		"move_left": KEY_A,
		"move_right": KEY_D,
		"move_up": KEY_W,
		"move_down": KEY_S,
		"jump": KEY_SPACE,
		"attack": MOUSE_BUTTON_LEFT,
		"aim": MOUSE_BUTTON_RIGHT,
		"swap_weapons": KEY_TAB,
		"pause": KEY_ESCAPE,
		"camera_left": KEY_Q,
		"camera_right": KEY_E,
		"camera_up": KEY_R,
		"camera_down": KEY_F,
	}
	for action in INPUT_ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var input_key = InputEventKey.new()
		input_key.keycode = INPUT_ACTIONS[action]
		InputMap.action_add_event(action, input_key)
