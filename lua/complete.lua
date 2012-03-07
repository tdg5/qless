-- Complete(0, id, worker, queue, now, [data, [next, [delay]]])
-- ------------------------------------------------------------
-- Complete a job and optionally put it in another queue, either scheduled or to
-- be considered waiting immediately.
--
-- Args:
--    1) id
--    2) worker
--    3) queue
--    4) now
--    5) [data]
--    6) [next]
--    7) [delay]

if #KEYS > 0 then error('Complete(): No Keys should be provided') end

local id     = assert(ARGV[1]          , 'Complete(): Arg "id" missing.')
local worker = assert(ARGV[2]          , 'Complete(): Arg "worker" missing.')
local queue  = assert(ARGV[3]          , 'Complete(): Arg "queue" missing.')
local now    = assert(tonumber(ARGV[4]), 'Complete(): Arg "now" not a number or missing: ' .. (ARGV[4] or 'nil'))
local data   = ARGV[5]
local nextq  = ARGV[6]
local delay  = assert(tonumber(ARGV[7] or 0), 'Complete(): Arg "delay" not a number: ' .. (ARGV[7] or 'nil'))

if data then
	data = cjson.decode(data)
end

-- First things first, we should see if the worker still owns this job
local lastworker, history, state, priority = unpack(redis.call('hmget', 'ql:j:' .. id, 'worker', 'history', 'state', 'priority'))
if (lastworker ~= worker) or (state ~= 'running') then
	return false
end

-- Now we can assume that the worker does own the job. We need to
--    1) Remove the job from the 'locks' from the old queue
--    2) Enqueue it in the next stage if necessary
--    3) Update the data
--    4) Mark the job as completed, remove the worker, remove expires, and update history

-- Unpack the history, and update it
history = cjson.decode(history)
history[#history]['done'] = now

if data then
	redis.call('hset', 'ql:j:' .. id, 'data', cjson.encode(data))
end

-- Remove the job from the previous queue
redis.call('zrem', 'ql:q:' .. queue .. '-work', id)
redis.call('zrem', 'ql:q:' .. queue .. '-locks', id)
redis.call('zrem', 'ql:q:' .. queue .. '-scheduled', id)

if nextq then
	-- Enqueue the job
	table.insert(history, {
		q     = nextq,
		put   = now
	})
	
	redis.call('hmset', 'ql:j:' .. id, 'state', 'waiting', 'worker', '',
		'queue', nextq, 'expires', 0, 'history', cjson.encode(history))
	
	if delay > 0 then
	    redis.call('zadd', 'ql:q:' .. nextq .. '-scheduled', now + delay, id)
	else
	    redis.call('zadd', 'ql:q:' .. nextq .. '-work', priority, id)
	end
	return 'waiting'
else
	redis.call('hmset', 'ql:j:' .. id, 'state', 'complete', 'worker', '',
		'queue', '', 'expires', 0, 'history', cjson.encode(history))
	
	-- Do the completion dance
	local count, time = unpack(redis.call('hmget', 'ql:config', 'jobs-history-count', 'jobs-history'))
	
	-- These are the default values
	count = tonumber(count or 50000)
	time  = tonumber(time  or 7 * 24 * 60 * 60)
	
	-- Schedule this job for destructination eventually
	redis.call('zadd', 'ql:completed', now, id)
	
	-- Now look at the expired job data. First, based on the current time
	local jids = redis.call('zrangebyscore', 'ql:completed', 0, now - time)
	-- Any jobs that need to be expired... delete
	for index, value in ipairs(jids) do
		redis.call('del', 'ql:j:' .. value)
	end
	-- And now remove those from the queued-for-cleanup queue
	redis.call('zremrangebyscore', 'ql:completed', 0, now)
	
	-- Now take the all by the most recent 'count' ids
	jids = redis.call('zrange', 'ql:completed', 0, -count)
	for index, value in ipairs(jids) do
		redis.call('del', 'ql:j:' .. value)
	end
	return 'complete'
end