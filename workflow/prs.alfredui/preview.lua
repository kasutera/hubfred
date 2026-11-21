local function attachment_url(target)
  if target:match('^/user%-attachments/assets/[a-fA-F0-9-]+$') then
    target = 'https://github.com' .. target
  end
  if target:match('^https://github%.com/user%-attachments/assets/[a-fA-F0-9-]+$') then
    return target
  end
end

function Image(image)
  local url = attachment_url(image.src)
  if url then return pandoc.Link('Open attachment in browser', url) end
  local caption = #image.caption > 0 and image.caption or {pandoc.Str('Open image in browser')}
  local scheme = image.src:lower():match('^([%a][%w+.-]*):')
  if not scheme or scheme == 'http' or scheme == 'https' then
    return pandoc.Link(caption, image.src)
  end
  return caption
end

-- GitHub may insert an HTML img tag when an attachment has a custom size.
-- Rebuild only the recognized attachment; never pass through raw attributes.
local function raw_attachment(raw)
  if raw.format ~= 'html' or not raw.text:lower():match('^%s*<img%s') then return {} end
  local blocks = pandoc.read(raw.text, 'html').blocks
  if #blocks ~= 1 then return {} end
  local block = blocks[1]
  if block.t ~= 'Plain' and block.t ~= 'Para' then return {} end
  if #block.content ~= 1 or block.content[1].t ~= 'Image' then return {} end
  local image = block.content[1]
  local url = attachment_url(image.src)
  if not url then return {} end
  return {pandoc.Link('Open attachment in browser', url)}
end

function RawInline(raw) return raw_attachment(raw) end
function RawBlock(raw)
  local content = raw_attachment(raw)
  if #content ~= 0 then return pandoc.Para(content) end
  return {}
end

function Link(link)
  local scheme = link.target:lower():match('^([%a][%w+.-]*):')
  if scheme and scheme ~= 'https' and scheme ~= 'http' then
    return link.content
  end
end
