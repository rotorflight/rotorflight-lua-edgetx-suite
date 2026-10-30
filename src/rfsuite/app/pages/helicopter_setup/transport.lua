-- One load, decode or dispatch per call. Replies never run a continuation or build UI.
local M = {}
local ROOT = "/SCRIPTS/TOOLS/rfsuite-core/tasks/msp/api/"
-- Every reply here comes from the flight controller, so the sample reply an API module carries
-- for offline use is dropped from the instance this page loads for itself. telemetry_config's
-- write builder starts from its sample, so that one keeps it.
local KEEP_SAMPLE = { telemetry_config = true }
function M.new(runtime, allowed, failed)
  local b = { apis = {}, jobs = {}, first = 1, generation = 0 }
  function b:load(name)
    local api = assert(loadScript(ROOT .. name .. ".lua", "t"))()
    if not KEEP_SAMPLE[name] then api.simulatorResponse = nil end
    self.apis[name] = api
    return api
  end
  function b:add(job)
    -- The controller does not tick an idle bus. Drop consumed batches before
    -- enqueueing again so a long polling visit cannot retain every old reply.
    if self:idle() then self.jobs, self.first = {}, 1 end
    self.jobs[#self.jobs + 1] = job
  end
  function b:urgent(job)
    if self:idle() then self.jobs, self.first = {}, 1 end
    table.insert(self.jobs, self.first, job)
  end
  function b:idle() return not self.pending and self.first > #self.jobs end
  function b:readOnly()
    if self.pending and self.pending.job.write then return false end
    if #self.jobs-self.first > 4 then return false end
    for i=self.first,#self.jobs do
      local j=self.jobs[i]
      if j.write or j.run or j.expand then return false end
    end
    return true
  end
  function b:queue() local s = runtime.getState(); return s and s.queue end
  function b:dropOverrides()
    local jobs = {}
    for i = self.first, #self.jobs do if not self.jobs[i].override then jobs[#jobs + 1] = self.jobs[i] end end
    self.jobs, self.first = jobs, 1
    if self.pending and self.pending.job.override then self.pending = nil end
    local q = self:queue(); if q then q:clear("helicopter-overrides") end
  end
  function b:dropApi(name)
    local keep={}
    for i=self.first,#self.jobs do if self.jobs[i].api~=name then keep[#keep+1]=self.jobs[i] end end
    self.jobs,self.first=keep,1
    if self.pending and self.pending.job.api==name then self.pending=nil end
  end
  function b:cancel()
    self.generation = self.generation + 1
    self.jobs, self.first, self.pending = {}, 1, nil
    local q = self:queue()
    if q then q:clear("helicopter-setup") end
  end
  function b:tick()
    if not allowed() then return end
    local p = self.pending
    if p then
      if not p.done then return end
      self.pending = nil
      local result = p.buf
      if not p.error and p.api.parse and (not p.job.write or p.job.decode) then
        result = p.api.parse(p.buf)
        if result == nil then p.error = "decode" end
      end
      if not p.error and p.job.api == "status" and type(p.buf) == "table" and #p.buf < 30 then p.error = "short status" end
      if p.error and not p.job.optional and not p.job.override then
        self.jobs, self.first = {}, 1
        failed(p.job.api, p.error)
      elseif p.job.after then
        p.job.after(result, p.error)
      end
      return
    end
    local j = self.jobs[self.first]
    if not j then self.jobs, self.first = {}, 1; return end
    local container = j
    if j.expand then
      local generation=self.generation
      if not j.current then j.current = j.expand() end
      if self.generation~=generation then return end
      j = j.current
      if not j then self.first = self.first + 1; return end
    end
    if j.run then
      if container == j then self.first = self.first + 1 else container.current = nil end
      j.run()
      return
    end
    local api = self.apis[j.api]
    if not api then
      self:load(j.api)
      return
    end
    local q = self:queue()
    if not q then return end
    local payload = j.payload
    if type(payload) == "function" then payload = payload() end
    if j.write and not payload then
      local data = j.data
      if type(data) == "function" then data = data() end
      if data == false then
        if container == j then self.first = self.first + 1 else container.current = nil end
        return
      end
      payload = api.buildWritePayload(data)
      if not payload then failed(j.api, "payload"); self.jobs, self.first = {}, 1; return end
    end
    local generation = self.generation
    p = { job = j, api = api }
    self.pending = p
    if container == j then self.first = self.first + 1 else container.current = nil end
    q:add({
      command = j.write and api.writeCommand or api.command,
      payload = payload or {}, isWrite = j.write == true,
      client = j.override and "helicopter-overrides" or "helicopter-setup",
      -- Queue timeouts are seconds; a lost override reply must leave room for the next refresh.
      timeout = j.override and 0.3 or j.timeout or 2, maxRetries = j.override and 0 or j.maxRetries or 0,
      retryOnErrorReply = j.retryOnErrorReply,
      processReply = function(_, buf)
        if self.generation == generation then p.buf, p.done = buf, true end
      end,
      errorHandler = function(_, reason)
        if self.generation == generation then p.error, p.done = reason or "reply", true end
      end
    })
  end
  return b
end
return M
