local M = {}

function M.board(raw)
	if not raw then
		return nil
	end
	return {
		id = raw.id,
		name = raw.name,
		type = raw.type,
	}
end

function M.boards(raw_boards)
	local out = {}
	for k, v in pairs(raw_boards or {}) do
		out[k] = M.board(v)
	end
	return out
end

function M.sprint(raw)
	if not raw then
		return nil
	end
	return {
		id = raw.id,
		name = raw.name,
		state = raw.state,
		startDate = raw.startDate,
		endDate = raw.endDate,
	}
end

function M.sprints(raw_sprints)
	local out = {}
	for k, v in pairs(raw_sprints or {}) do
		out[k] = M.sprint(v)
	end
	return out
end

function M.epics(raw_epics)
	local out = {}
	for _, epic in ipairs(raw_epics or {}) do
		if epic.fields and (epic.fields.status.name == "In Progress" or epic.fields.status.name == "To Do") then
			table.insert(out, {
				key = epic.key,
				summary = epic.fields.summary,
				status = epic.fields.status.name,
			})
		end
	end
	return out
end

function M.epics_by_project(raw_epics)
	local out = {}
	for k, v in pairs(raw_epics or {}) do
		out[k] = M.epics(v)
	end
	return out
end

function M.users(raw_users)
	local out = {}
	for _, user in ipairs(raw_users or {}) do
		table.insert(out, {
			accountId = user.accountId,
			displayName = user.displayName,
		})
	end
	return out
end

return M
