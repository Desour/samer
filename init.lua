local load_time_start = os.clock()
local modname = minetest.get_current_modname()


-- entity helpers:

local samer_ids = {} -- This stores active_object_ids.

local function get_inv(id)
	return minetest.get_inventory({type = "detached", name = "samer:samer"..id})
end

local function get_code(id)
	return minetest.luaentities[samer_ids[id]].code
end

local function yaw_to_param2(yaw)
	return (-2 * (yaw / math.pi - 2)) % 4
end

local function param2_to_yaw(param2)
	return (2 - param2 / 2) * math.pi
end

local function transfer_inv(inv, old_inv)
	local old_lists = old_inv:get_lists()
	for listname, _ in pairs(old_lists) do
		inv:set_size(listname, old_inv:get_size(listname))
	end
	inv:set_lists(old_lists)
end

local function inv_content_to_inv(inv, inv_content)
	for listname, list in pairs(inv_content) do
		inv:set_size(listname, #list)
		for i = 1, #list do
			list[i] = ItemStack(list[i])
		end
		inv:set_list(listname, list)
	end
end

local function node_to_ent(pos, meta, code)
	local samer = minetest.add_entity(pos, "samer:samer", minetest.serialize({
		code = code,
		id = -1, -- The entity gets its id by itself on_activate.
	}))
	local id
	for i, obj in pairs(minetest.object_refs) do
		if obj == samer then
			id = i
			break
		end
	end
	if not id then
		return
	end
	samer:set_yaw(param2_to_yaw(minetest.get_node(pos).param2))
	samer_ids[id] = id
	local inv = minetest.create_detached_inventory("samer:samer"..id, {})
	transfer_inv(inv, meta:get_inventory())
	minetest.remove_node(pos)
	return id
end

local function ent_to_node(id)
	local luaent = minetest.luaentities[samer_ids[id]]
	local obj = luaent.object
	local pos = obj:get_pos()
	minetest.set_node(pos,
			{name = "samer:samer", param2 = yaw_to_param2(obj:get_yaw())})
	local meta = minetest.get_meta(pos)
	meta:set_string("code", luaent.code)
	local old_inv = get_inv(id)
	local inv = meta:get_inventory()
	if old_inv then
		transfer_inv(inv, old_inv)
	else
		inv_content_to_inv(inv, luaent.inv_content)
	end
	obj:remove()
end


-- running the code:

local waiting_threads = {}

local function create_environment(id)
	-- todo: finish this
	local env = {
		sleep = coroutine.yield,
		say = function(msg)
			minetest.chat_send_all("<samer> "..msg)
		end,
		get_pos = function()
			return minetest.object_refs[samer_ids[id]]:get_pos()
		end,
		get_yaw = function()
			return minetest.object_refs[samer_ids[id]]:get_yaw()
		end,
		move = function()
			local obj = minetest.object_refs[samer_ids[id]]
			local dir = minetest.yaw_to_dir(obj:get_yaw())
			local new_pos = vector.add(obj:get_pos(), dir)
			local node_def = minetest.registered_nodes[minetest.get_node(new_pos).name]
			if not node_def or node_def.walkable then
				return false
			end
			local speed = 1
			obj:set_velocity(vector.multiply(dir, speed))
			coroutine.yield(1 / speed)
			obj:set_velocity(vector.new())
			obj:set_pos(new_pos)
			return true
		end,
		turn = function(dir)
			if type(dir) ~= "number" then
				error()
			end
			dir = math.sign(dir)
			local obj = minetest.object_refs[samer_ids[id]]
			obj:set_yaw(obj:get_yaw() + dir * math.pi / 2)
			coroutine.yield(0.5)
		end,
		dig = function()
			local obj = minetest.object_refs[samer_ids[id]]
			local dir = minetest.yaw_to_dir(obj:get_yaw())
			local node_pos = vector.add(obj:get_pos(), dir)
			minetest.remove_node(node_pos)
			coroutine.yield(0.5)
		end,
	}
	env._G = env
	return env
end

local function create_thread(func, env)
	-- todo: do more for safety
	setfenv(func, env)
	return coroutine.create(pcall), func
end

local function run(id, thread, func)
	if not minetest.object_refs[samer_ids[id]] then  -- samer unloaded
		waiting_threads[id] = thread
		return
	end
	local ok, msg = coroutine.resume(thread, func)
	if ok and msg and type(msg) == "number" and msg >= 0 then
		minetest.after(msg, run, id, thread)
	else
		ent_to_node(id)
	end
end


-- formspec stuff:

local ask_close_code = {}

local function show_normal_formspec_node(player, pos, code, msg)
	minetest.show_formspec(player:get_player_name(),
			"samer:node"..minetest.pos_to_string(pos),
		"size[15,11]"..
		"button[0,2;3,1;inv;Inventory]"..
		"button[0,3;3,1;save;Save]"..
		"button[0,4;3,1;interpret;Interpret]"..
		"button[0,5;3,1;run;Run]"..
		"button[0,10;3,1;exit;Exit]"..
		"button[14.6,0;0.5,0.5;x;X]"..
		(msg and "label[0,6;"..minetest.formspec_escape(msg).."]" or "")..
		"textarea[4,0;11,13;code;;"..minetest.formspec_escape(code).."]"..
		default.gui_bg..
		default.gui_bg_img
	)
end

local function show_inventory_formspec_node(player, pos)
	local pos_s = minetest.pos_to_string(pos)
	minetest.show_formspec(player:get_player_name(),
			"samer:node"..pos_s.."inv",
		"size[8,9]"..
		"button[0,8.2;2,1;back;Back]"..
		"list[current_player;main;0,3.85;8,1;]"..
		"list[current_player;main;0,5.08;8,3;8]"..
		"list[nodemeta:"..pos_s:sub(2,-2)..";main;1,0.3;6,3;]"..
		"listring[]"..
		default.get_hotbar_bg(0,3.85)..
		default.gui_bg..
		default.gui_bg_img..
		default.gui_slots
	)
end

local function show_ask_close_formspec_node(player, pos)
	minetest.show_formspec(player:get_player_name(),
			"samer:node"..minetest.pos_to_string(pos).."ask_close",
		"size[6,2.2]"..
		"label[1,0.1;Do you want to save your code before exiting?]"..
		"button[0,1.4;2,1;cancel;Cancel]"..
		"button_exit[2,1.4;2,1;discard;Discard]"..
		"button_exit[4,1.4;2,1;save;Save]"..
		default.gui_bg..
		default.gui_bg_img
	)
end

local function on_node_receive_fields(player, pos, formname, fields)
	if formname == "inv" then
		if fields.back then
			show_normal_formspec_node(player, pos, ask_close_code[player])
			ask_close_code[player] = nil
		elseif fields.quit then
			minetest.after(0.1, show_normal_formspec_node, player, pos,
					ask_close_code[player])
			ask_close_code[player] = nil
		end
		return
	elseif formname == "ask_close" then
		if fields.cancel then
			show_normal_formspec_node(player, pos, ask_close_code[player])
		elseif fields.save then
			minetest.get_meta(pos):set_string("code", ask_close_code[player])
		elseif not fields.discard and fields.quit then
			minetest.after(0.1, show_normal_formspec_node, player, pos,
					ask_close_code[player])
		end
		ask_close_code[player] = nil
		return
	elseif formname ~= "" then
		return
	end
	local meta = minetest.get_meta(pos)
	if fields.save then
		meta:set_string("code", fields.code)
		show_normal_formspec_node(player, pos, fields.code, "Code saved.")
	elseif fields.inv then
		ask_close_code[player] = fields.code
		show_inventory_formspec_node(player, pos)
	elseif fields.run then
		local func, msg = loadstring(fields.code)
		if func then
			minetest.close_formspec(player:get_player_name(),
					"samer:node"..minetest.pos_to_string(pos))
			local id = node_to_ent(pos, meta, fields.code)
			run(id, create_thread(func, create_environment(id)))
		else
			show_normal_formspec_node(player, pos, fields.code, msg)
		end
	elseif fields.interpret then
		local func, msg = loadstring(fields.code)
		if func then
			meta:set_string("code", fields.code)
			show_normal_formspec_node(player, pos, fields.code,
					"Code interpreted and saved.")
		else
			show_normal_formspec_node(player, pos, fields.code, msg)
		end
	elseif fields.exit or fields.x then
		if fields.code ~= meta:get_string("code") then
			ask_close_code[player] = fields.code
			show_ask_close_formspec_node(player, pos)
		else
			minetest.close_formspec(player:get_player_name(),
					"samer:node"..minetest.pos_to_string(pos))
		end
	end
end

local function show_normal_formspec_entity(player, id)
	minetest.show_formspec(player:get_player_name(),
			"samer:entity("..id..")",
		"size[15,11]"..
		"button[0,2;3,1;inv;Inventory]"..
		"button_exit[0,10;3,1;exit;Exit]"..
		"button_exit[14.6,0;0.5,0.5;x;X]"..
		"label[0,6;Running...]"..
		"textarea[4,0;11,13;code;;"..minetest.formspec_escape(get_code(id)).."]"..
		default.gui_bg..
		default.gui_bg_img
	)
end

local function show_inventory_formspec_entity(player, id)
	minetest.show_formspec(player:get_player_name(),
			"samer:entity("..id..")inv",
		"size[8,9]"..
		"button[0,8.2;2,1;back;Back]"..
		"list[current_player;main;0,3.85;8,1;]"..
		"list[current_player;main;0,5.08;8,3;8]"..
		"list[detached:samer:samer"..id..";main;1,0.3;6,3;]"..
		"listring[]"..
		default.get_hotbar_bg(0,3.85)..
		default.gui_bg..
		default.gui_bg_img..
		default.gui_slots
	)
end

local function on_entity_receive_fields(player, id, formname, fields)
	if formname == "inv" then
		if fields.back then
			show_normal_formspec_entity(player, id)
		elseif fields.quit then
			minetest.after(show_normal_formspec_entity, player, id)
		end
	elseif formname == "" and fields.inv then
		show_inventory_formspec_entity(player, id)
	end
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname:sub(1, 6) ~= "samer:" then
		return
	end
	formname = formname:sub(7)
	if formname:sub(1, 4) == "node" then
		local f = formname:find(")")
		local pos = minetest.string_to_pos(formname:sub(5, f))
		formname = formname:sub(f+1)
		on_node_receive_fields(player, pos, formname, fields)
	elseif formname:sub(1, 6) == "entity" then
		local f = formname:find(")")
		local id = tonumber(formname:sub(8, f-1))
		formname = formname:sub(f+1)
		on_entity_receive_fields(player, id, formname, fields)
	end
	return true
end)


-- registration of node and entity:

minetest.register_node("samer:samer", {
	description = "samer",
	groups = {oddly_breakable_by_hand = 1},
	wield_scale = {x = 0.1, y = 0.1, z = 0.1},
	drawtype = "mesh",
	visual_scale = 0.1,
	tiles = {{name = "samer_samer.png", backface_culling = true}},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	mesh = "samer_samer.b3d",
	selection_box = {
		type = "fixed",
		fixed = {-0.5, -0.5, -0.5, 0.5, 1/8, 0.5},
	},
	collision_box = {
		type = "fixed",
		fixed = {
			{-0.5, -0.5, -0.5, 0.5, -1/4, 0.5},
			{-1/8, -0.5, -1/8, 1/8,  1/8, 0.5},
		}
	},
	sounds = default.node_sound_metal_defaults(),

	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		meta:set_string("code", "")
		meta:get_inventory():set_size("main", 6*3)
	end,

	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		show_normal_formspec_node(clicker, pos,
				minetest.get_meta(pos):get_string("code"))
		return itemstack
	end,

	on_rotate = minetest.global_exists("screwdriver") and screwdriver.rotate_simple,
})


minetest.register_entity("samer:samer", {
	hp_max = 11,
	physical = true,
	collide_with_objects = false,
	weight = 5,
	collisionbox = {
		{-0.5, -0.5, -0.5, 0.5, -1/4, 0.5},
		{-1/8, -0.5, -1/8, 1/8,  1/8, 0.5},
	},
	selectionbox = {-0.5, -0.5, -0.5, 0.5, 1/8, 0.5},
	visual = "mesh",
	visual_size = {x = 1, y = 1},
	mesh = "samer_samer.b3d",
	textures = {"samer_samer.png"},
	makes_footstep_sound = true,
	stepheight = 0,
	backface_culling = true,

	on_activate = function(self, staticdata, dtime_s)
		local s = minetest.deserialize(staticdata)
		if not s or not s.id then
			self.object:remove()
			return
		end
		self.code = s.code
		self.id = s.id
		local stop = false
		for i, luaent in pairs(minetest.luaentities) do
			if luaent == self then
				if self.id == -1 then -- new samer
					self.id = i
				elseif not samer_ids[self.id] then -- samer from last game
					stop = true
				end
				samer_ids[self.id] = i
				break
			end
		end
		if waiting_threads[self.id] then -- samer was unloaded but can continue now
			run(self.id, waiting_threads[self.id])
			waiting_threads[id] = nil
		elseif stop then
			self.inv_content = s.inv_content
			ent_to_node(self.id)
		end
	end,

	on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
		-- do not die
	end,

	on_rightclick = function(self, clicker)
		show_normal_formspec_entity(clicker, self.id, self.code)
	end,

	get_staticdata = function(self)
		local inv_content = {}
		local inv = get_inv(self.id)
		if inv then
			for listname, list in pairs(inv:get_lists()) do
				inv_content[listname] = {}
				for i = 1, #list do
					inv_content[listname][i] = list[i]:to_string()
				end
			end
		end
		return minetest.serialize({
			code = self.code,
			id = self.id,
			inv_content = inv_content,
		})
	end,
})


local time = math.floor(tonumber(os.clock()-load_time_start)*100+0.5)/100
local msg = "["..modname.."] loaded after ca. "..time
if time > 0.05 then
	print(msg)
else
	minetest.log("info", msg)
end
