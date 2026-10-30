-- A bounded in-memory filesystem implementing EdgeTX's file-handle API.
-- It exercises the real store without creating radio files or running a simulator.
return function()
  local fs = {files={},failure=nil}
  function fs:install()
    self.original = {io=io,mkdir=mkdir,rename=rename,del=del}
    io = {
      open=function(path,mode)
        if mode=="w" then
          if fs.failure=="open" then return nil end
          fs.files[path]="";return {path=path,mode=mode}
        end
        if fs.files[path]~=nil then return {path=path,offset=0,mode=mode} end
      end,
      read=function(file,count)
        assert(count==64,"history reads stay bounded to 64 bytes")
        local text=string.sub(fs.files[file.path],file.offset+1,file.offset+count)
        file.offset=file.offset+#text;return text
      end,
      write=function(file,body)
        if fs.failure=="write" then return false end
        fs.files[file.path]=fs.failure=="short" and string.sub(body,1,4) or body
        return true
      end,
      close=function() end
    }
    mkdir=function() return fs.failure=="mkdir" and 6 or 0 end
    del=function(path)
      if fs.failure=="delete" then return 7 end
      fs.files[path]=nil;return 0
    end
    rename=function(from,to)
      if fs.failure=="rename" then return 7 end
      assert(fs.files[to]==nil,"FatFs cannot rename onto an existing file")
      fs.files[to],fs.files[from]=fs.files[from],nil
      if fs.failure=="readback" then fs.files[to]="return { version = 1, completed = 0 }\n" end
      return 0
    end
  end
  function fs:restore()
    io,mkdir,rename,del=self.original.io,self.original.mkdir,self.original.rename,self.original.del
  end
  return fs
end
