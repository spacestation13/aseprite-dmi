--- @diagnostic disable: lowercase-global

--- Finds the first transparent color in the given image.
--- @param image Image The image to search for transparent color.
--- @return Color color The first transparent color found in the image, or a fully transparent black color if no transparent color is found.
function transparent_color(image)
	for it in image:pixels() do
		local color = Color(it())
		if color.alpha == 0 then
			if color.index == 0 then
				return color
			end
		end
	end
	return Color(0)
end

--- Function to load image from bytes file.
--- Thanks to `Astropulse` for sharing [this](https://community.aseprite.org/t/loading-ui-images-for-graphicscontext-elements-at-lightning-speed/21128) article.
--- @param file string The path to the file.
--- @return Image|nil image The image loaded from the file.
function load_image_bytes(file)
	local file = io.open(file, "rb")

	if not file then return nil end

	local width = tonumber(file:read("*line"))
	local height = tonumber(file:read("*line"))
	local bytes = file:read("*a")

	file:close()

	if not width or not height or not bytes then return nil end

	local image = Image(ImageSpec {
		width = width,
		height = height,
		colorMode = ColorMode.RGB,
		transparentColor = app.pixelColor.rgba(0, 0, 0, 0)
	})
	image.bytes = bytes

	return image
end

--- Splits one line of credits into words, each `{ text, url, space }` (`space`: whitespace before
--- it). Understands `[label](https://url)`; the rest is plain text.
--- @param line string
--- @return table[]
function credits_words(line)
	local words = {}
	local trailing = false -- the previous piece ended with whitespace
	local function add(text, url)
		for space, word in text:gmatch("(%s*)(%S+)") do
			table.insert(words, { text = word, url = url, space = space ~= "" or trailing })
			trailing = false
		end
		trailing = trailing or text:find("%s$") ~= nil
	end

	local pos = 1
	while pos <= #line do
		local start, finish, label, url = line:find("%[([^%]]+)%]%((https://[^%s)]+)%)", pos)
		if not start then
			add(line:sub(pos))
			break
		end
		add(line:sub(pos, start - 1))
		add(label, url)
		pos = finish + 1
	end
	return words
end

--- Shows the extension's CREDITS.txt in a dialog. Supports `[label](https://url)` links.
--- @param path string
function show_credits(path)
	local handle = io.open(path, "r")
	local text = "CREDITS.txt is missing from this install."
	if handle then
		text = handle:read("a")
		handle:close()
	end

	local WIDTH, PAD, LINE = 275, 4, 12
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		table.insert(lines, credits_words(line))
	end
	-- Height estimate from the text without link markup (the canvas can't be resized after it exists).
	local plain = text:gsub("%[([^%]]+)%]%([^)]*%)", "%1")
	local height = PAD * 2 + (#plain:split_lines(WIDTH // 5) + 1) * LINE

	local hits = {}
	local dialog = Dialog { title = "DMI Editor - Credits" }
	dialog:canvas {
		width = WIDTH,
		height = height,
		onpaint = function(ev)
			local ctx = ev.context
			local link_color = Color { r = 40, g = 110, b = 220, a = 255 }
			local space = math.max(4, ctx:measureText(" ").width)
			hits = {}
			local y = PAD
			for _, words in ipairs(lines) do
				local x = PAD
				for _, word in ipairs(words) do
					local width = ctx:measureText(word.text).width
					local gap = (word.space and x > PAD) and space or 0
					if x > PAD and x + gap + width > ctx.width - PAD then
						x, y, gap = PAD, y + LINE, 0
					end
					x = x + gap
					ctx.color = word.url and link_color or app.theme.color.text
					ctx:fillText(word.text, x, y)
					if word.url then
						local text_height = ctx:measureText(word.text).height
						ctx:fillRect(Rectangle(x, y + text_height, width, 1))
						table.insert(hits, { rect = Rectangle(x, y, width, text_height + 1), url = word.url })
					end
					x = x + width
				end
				y = y + LINE
			end
		end,
		onmousedown = function(ev)
			for _, hit in ipairs(hits) do
				if hit.rect:contains(Point(ev.x, ev.y)) then
					local _, err = libdmi.open_url(hit.url)
					if err then app.alert { title = "Error", text = tostring(err) } end
					return
				end
			end
		end,
	}
	dialog:button { text = "&Close", focus = true }
	dialog:show { wait = false }
end
