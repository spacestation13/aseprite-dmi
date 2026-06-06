local DEFAULT_PREVIEW_DELAY = 1
local ANIMATION_TICK_INTERVAL = 1 / 30
local MAX_PREVIEW_FRAMES = 2048

local function sanitize_delay(value)
	local delay = tonumber(value) or DEFAULT_PREVIEW_DELAY
	if delay ~= delay or delay == math.huge or delay == -math.huge then
		return DEFAULT_PREVIEW_DELAY
	end
	return math.max(delay, DEFAULT_PREVIEW_DELAY)
end

function Editor:preview_frame_for_state(state, now)
	local raw_count = tonumber(state.frame_count) or 1
	if raw_count ~= raw_count or raw_count == math.huge or raw_count == -math.huge then
		raw_count = 1
	end

	local frame_count = math.max(1, math.floor(raw_count))

	local cached_frames = self.image_cache and self.image_cache.images and self.image_cache.images[state.frame_key]
	if cached_frames and #cached_frames > 0 then
		frame_count = math.min(frame_count, #cached_frames)
	end

	frame_count = math.min(frame_count, MAX_PREVIEW_FRAMES)
	if frame_count <= 1 then
		return 1
	end

	local delays = state.delays or {}
	local function frame_delay(f)
		return sanitize_delay(delays[f] or delays[1])
	end

	-- rewind: play forward (1..N) then backward (N-1..2), ping-pong loop
	local rewind = state.rewind and frame_count > 2

	local total_delay = 0
	for frame = 1, frame_count do
		total_delay = total_delay + frame_delay(frame)
	end
	if rewind then
		for frame = frame_count - 1, 2, -1 do
			total_delay = total_delay + frame_delay(frame)
		end
	end

	if total_delay <= 0 or total_delay ~= total_delay or total_delay == math.huge then
		return 1
	end

	local elapsed = (now * 10) % total_delay
	local cumulative = 0
	for frame = 1, frame_count do
		cumulative = cumulative + frame_delay(frame)
		if elapsed < cumulative then
			return frame
		end
	end
	if rewind then
		for frame = frame_count - 1, 2, -1 do
			cumulative = cumulative + frame_delay(frame)
			if elapsed < cumulative then
				return frame
			end
		end
	end

	return frame_count
end

function Editor:preview_image_for_widget(widget, now)
	if widget.type ~= "IconWidget" then
		return widget.icon
	end

	local state = widget.iconstate
	if not state then
		return widget.icon
	end

	if not (Preferences.getAnimatePreviews and Preferences.getAnimatePreviews()) then
		return self.image_cache:get(state.frame_key, 1) or widget.icon
	end

	local cached_frames = self.image_cache and self.image_cache.images and self.image_cache.images[state.frame_key]
	if not cached_frames or #cached_frames <= 1 then
		return self.image_cache:get(state.frame_key, 1) or widget.icon
	end

	local frame = self:preview_frame_for_state(state, now)
	return self.image_cache:get(state.frame_key, frame) or self.image_cache:get(state.frame_key, 1) or widget.icon
end

function Editor:has_visible_animated_previews()
	if not self.dmi then
		return false
	end

	if not (Preferences.getAnimatePreviews and Preferences.getAnimatePreviews()) then
		return false
	end

	for _, widget in ipairs(self.widgets) do
		if widget.type == "IconWidget" then
			local state = widget.iconstate
			local cached_frames = state and self.image_cache and self.image_cache.images and self.image_cache.images[state.frame_key]
			if state and cached_frames and #cached_frames > 1 and math.max(1, math.floor(state.frame_count or 1)) > 1 then
				return true
			end
		end
	end

	return false
end

function Editor:stop_animation_timer()
	if self.animation_timer and self.animation_running then
		self.animation_timer:stop()
		self.animation_running = false
	end
end

function Editor:update_animation_timer(should_run)
	if not self.animation_timer then
		local timer_constructor = rawget(_G, "Timer")
		if type(timer_constructor) ~= "function" then
			return
		end

		local ok, timer = pcall(function()
			return timer_constructor {
				interval = ANIMATION_TICK_INTERVAL,
				ontick = function()
					-- Nudge the GC on every tick so transient userdata objects
					-- (Rectangles, Sizes, etc. created during repaints) are collected
					-- promptly rather than accumulating between GC cycles.
					collectgarbage("step")

					if self.closed or not self.dialog or self.loading then
						return
					end

					if not self:has_visible_animated_previews() then
						self:update_animation_timer(false)
						return
					end

					self:repaint()
				end
			}
		end)

		if not ok then
			return
		end

		self.animation_timer = timer
	end

	if should_run then
		if not self.animation_running then
			self.animation_timer:start()
			self.animation_running = true
		end
	else
		self:stop_animation_timer()
	end
end
