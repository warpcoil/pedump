#!/usr/bin/env ruby
require 'stringio'
require 'pedump/core'
require 'pedump/pe'
require 'pedump/resources'
require 'pedump/version_info'
require 'pedump/tls'

# pedump.rb by zed_0xff
#
#   http://zed.0xff.me
#   http://github.com/zed-0xff

class PEdump
  attr_accessor :fname, :logger, :force

  VERSION = Version::STRING

  @@logger = nil

  def initialize fname=nil, params = {}
    @fname = fname
    @force = params[:force]
    @logger = @@logger = Logger.create(params)
  end

  # http://www.delorie.com/djgpp/doc/exe/
  MZ = create_struct( "a2v13Qv2V6",
    :signature,
    :bytes_in_last_block,
    :blocks_in_file,
    :num_relocs,
    :header_paragraphs,
    :min_extra_paragraphs,
    :max_extra_paragraphs,
    :ss,
    :sp,
    :checksum,
    :ip,
    :cs,
    :reloc_table_offset,
    :overlay_number,
    :reserved0,           #  8 reserved bytes
    :oem_id,
    :oem_info,
    :reserved2,           # 20 reserved bytes
    :reserved3,
    :reserved4,
    :reserved5,
    :reserved6,
    :lfanew
  )

  # http://msdn.microsoft.com/en-us/library/ms809762.aspx
  class IMAGE_FILE_HEADER < create_struct( 'v2V3v2',
    :Machine,              # w
    :NumberOfSections,     # w
    :TimeDateStamp,        # dw
    :PointerToSymbolTable, # dw
    :NumberOfSymbols,      # dw
    :SizeOfOptionalHeader, # w
    :Characteristics       # w
  )
    # Characteristics, http://msdn.microsoft.com/en-us/library/windows/desktop/ms680313(v=VS.85).aspx)
    FLAGS = {
      0x0001 => 'RELOCS_STRIPPED',          # Relocation information was stripped from the file.
                                            # The file must be loaded at its preferred base address.
                                            # If the base address is not available, the loader reports an error.
      0x0002 => 'EXECUTABLE_IMAGE',
      0x0004 => 'LINE_NUMS_STRIPPED',
      0x0008 => 'LOCAL_SYMS_STRIPPED',
      0x0010 => 'AGGRESIVE_WS_TRIM',        # Aggressively trim the working set. This value is obsolete as of Windows 2000.
      0x0020 => 'LARGE_ADDRESS_AWARE',      # The application can handle addresses larger than 2 GB.
      0x0040 => '16BIT_MACHINE',
      0x0080 => 'BYTES_REVERSED_LO',        # The bytes of the word are reversed. This flag is obsolete.
      0x0100 => '32BIT_MACHINE',
      0x0200 => 'DEBUG_STRIPPED',
      0x0400 => 'REMOVABLE_RUN_FROM_SWAP',
      0x0800 => 'NET_RUN_FROM_SWAP',
      0x1000 => 'SYSTEM',
      0x2000 => 'DLL',
      0x4000 => 'UP_SYSTEM_ONLY',           # The file should be run only on a uniprocessor computer.
      0x8000 => 'BYTES_REVERSED_HI'         # The bytes of the word are reversed. This flag is obsolete.
    }

#    def initialize *args
#      super
#      self.TimeDateStamp = Time.at(self.TimeDateStamp).utc
#    end
    def flags
      FLAGS.find_all{ |k,v| (self.Characteristics & k) != 0 }.map(&:last)
    end
  end

  module IMAGE_OPTIONAL_HEADER
    # DllCharacteristics, http://msdn.microsoft.com/en-us/library/windows/desktop/ms680339(v=vs.85).aspx)
    FLAGS = {
      0x0001 => '0x01', # reserved
      0x0002 => '0x02', # reserved
      0x0004 => '0x04', # reserved
      0x0008 => '0x08', # reserved
      0x0010 => '0x10', # ?
      0x0020 => '0x20', # ?
      0x0040 => 'DYNAMIC_BASE',
      0x0080 => 'FORCE_INTEGRITY',
      0x0100 => 'NX_COMPAT',
      0x0200 => 'NO_ISOLATION',
      0x0400 => 'NO_SEH',
      0x0800 => 'NO_BIND',
      0x1000 => '0x1000',               # ?
      0x2000 => 'WDM_DRIVER',
      0x4000 => '0x4000',               # ?
      0x8000 => 'TERMINAL_SERVER_AWARE'
    }
    def initialize *args
      super
      self.extend InstanceMethods
    end
    def self.included base
      base.extend ClassMethods
    end
    module ClassMethods
      def read file, size = nil
        usual_size = self.const_get('USUAL_SIZE')
        cSIZE   = self.const_get 'SIZE'
        cFORMAT = self.const_get 'FORMAT'
        size ||= cSIZE
        PEdump.logger.warn "[?] unusual size of IMAGE_OPTIONAL_HEADER = #{size} (must be #{usual_size})" if size != usual_size
        PEdump.logger.warn "[?] #{size-usual_size} spare bytes after IMAGE_OPTIONAL_HEADER" if size > usual_size
        new(*file.read([size,cSIZE].min).to_s.unpack(cFORMAT)).tap do |ioh|
          ioh.DataDirectory = []

          # check if "...this address is outside the memory mapped file and is zeroed by the OS"
          # see http://www.phreedom.org/solar/code/tinype/, section "Removing the data directories"
          ioh.each_pair{ |k,v| ioh[k] = 0 if v.nil? }

          # http://opcode0x90.wordpress.com/2007/04/22/windows-loader-does-it-differently/
          # maximum of 0x10 entries, even if bigger
          [0x10,ioh.NumberOfRvaAndSizes].min.times do |idx|
            ioh.DataDirectory << IMAGE_DATA_DIRECTORY.read(file)
            ioh.DataDirectory.last.type = IMAGE_DATA_DIRECTORY::TYPES[idx]
          end
          #ioh.DataDirectory.pop while ioh.DataDirectory.last.empty?

          # skip spare bytes, if any. XXX may contain suspicious data
          file.seek(size-usual_size, IO::SEEK_CUR) if size > usual_size
        end
      end
    end
    module InstanceMethods
      def flags
        FLAGS.find_all{ |k,v| (self.DllCharacteristics & k) != 0 }.map(&:last)
      end
    end
  end

  # http://msdn.microsoft.com/en-us/library/ms809762.aspx
  class IMAGE_OPTIONAL_HEADER32 < create_struct( 'vC2V9v6V4v2V6',
    :Magic, # w
    :MajorLinkerVersion, :MinorLinkerVersion, # 2b
    :SizeOfCode, :SizeOfInitializedData, :SizeOfUninitializedData, :AddressOfEntryPoint, # 9dw
    :BaseOfCode, :BaseOfData, :ImageBase, :SectionAlignment, :FileAlignment,
    :MajorOperatingSystemVersion, :MinorOperatingSystemVersion, # 6w
    :MajorImageVersion, :MinorImageVersion, :MajorSubsystemVersion, :MinorSubsystemVersion,
    :Reserved1, :SizeOfImage, :SizeOfHeaders, :CheckSum, # 4dw
    :Subsystem, :DllCharacteristics, # 2w
    :SizeOfStackReserve, :SizeOfStackCommit, :SizeOfHeapReserve, :SizeOfHeapCommit, # 6dw
    :LoaderFlags, :NumberOfRvaAndSizes,
    :DataDirectory # readed manually
  )
    USUAL_SIZE = 224
    include IMAGE_OPTIONAL_HEADER
  end

  # http://msdn.microsoft.com/en-us/library/windows/desktop/ms680339(v=VS.85).aspx)
  class IMAGE_OPTIONAL_HEADER64 < create_struct( 'vC2V5QV2v6V4v2Q4V2',
    :Magic, # w
    :MajorLinkerVersion, :MinorLinkerVersion, # 2b
    :SizeOfCode, :SizeOfInitializedData, :SizeOfUninitializedData, :AddressOfEntryPoint, :BaseOfCode, # 5dw
    :ImageBase, # qw
    :SectionAlignment, :FileAlignment, # 2dw
    :MajorOperatingSystemVersion, :MinorOperatingSystemVersion, # 6w
    :MajorImageVersion, :MinorImageVersion, :MajorSubsystemVersion, :MinorSubsystemVersion,
    :Reserved1, :SizeOfImage, :SizeOfHeaders, :CheckSum, # 4dw
    :Subsystem, :DllCharacteristics, # 2w
    :SizeOfStackReserve, :SizeOfStackCommit, :SizeOfHeapReserve, :SizeOfHeapCommit, # 4qw
    :LoaderFlags, :NumberOfRvaAndSizes, #2dw
    :DataDirectory # readed manually
  )
    USUAL_SIZE = 240
    include IMAGE_OPTIONAL_HEADER
  end

  IMAGE_DATA_DIRECTORY = create_struct( "VV", :va, :size, :type )
  IMAGE_DATA_DIRECTORY::TYPES =
    %w'EXPORT IMPORT RESOURCE EXCEPTION SECURITY BASERELOC DEBUG ARCHITECTURE GLOBALPTR TLS LOAD_CONFIG
    Bound_IAT IAT Delay_IAT CLR_Header'
  IMAGE_DATA_DIRECTORY::TYPES.each_with_index do |type,idx|
    IMAGE_DATA_DIRECTORY.const_set(type,idx)
  end

  IMAGE_SECTION_HEADER = create_struct( 'A8V6v2V',
    :Name, # A8 6dw
    :VirtualSize, :VirtualAddress, :SizeOfRawData, :PointerToRawData, :PointerToRelocations, :PointerToLinenumbers,
    :NumberOfRelocations, :NumberOfLinenumbers, # 2w
    :Characteristics # dw
  )
  class IMAGE_SECTION_HEADER
    alias :flags :Characteristics
    alias :va    :VirtualAddress
    def flags_desc
      r = ''
      f = self.flags.to_i
      r << (f & 0x4000_0000 > 0 ? 'R' : '-')
      r << (f & 0x8000_0000 > 0 ? 'W' : '-')
      r << (f & 0x2000_0000 > 0 ? 'X' : '-')
      r << ' CODE'        if f & 0x20 > 0

      # section contains initialized data. Almost all sections except executable and the .bss section have this flag set
      r << ' IDATA'       if f & 0x40 > 0

      # section contains uninitialized data (for example, the .bss section)
      r << ' UDATA'       if f & 0x80 > 0

      r << ' DISCARDABLE' if f & 0x02000000 > 0
      r << ' SHARED'      if f & 0x10000000 > 0
      r
    end

    def pack
      to_a.pack FORMAT.tr('A','a') # pad names with NULL bytes on pack()
    end
  end

  # http://msdn.microsoft.com/en-us/library/windows/desktop/ms680339(v=VS.85).aspx
  IMAGE_SUBSYSTEMS = %w'UNKNOWN NATIVE WINDOWS_GUI WINDOWS_CUI' + [nil,'OS2_CUI',nil,'POSIX_CUI',nil] +
    %w'WINDOWS_CE_GUI EFI_APPLICATION EFI_BOOT_SERVICE_DRIVER EFI_RUNTIME_DRIVER EFI_ROM XBOX' +
    [nil, 'WINDOWS_BOOT_APPLICATION']

  # http://ntcore.com/files/richsign.htm
  class RichHdr < String
    attr_accessor :offset, :key # xor key

    class Entry < Struct.new(:version,:id,:times)
      def inspect
        "<id=#{id}, version=#{version}, times=#{times}>"
      end
    end

    def self.from_dos_stub stub
      key = stub[stub.index('Rich')+4,4]
      start_idx = stub.index(key.xor('DanS'))
      end_idx   = stub.index('Rich')+8
      if stub[end_idx..-1].tr("\x00",'') != ''
        t = stub[end_idx..-1]
        t = "#{t[0,0x100]}..." if t.size > 0x100
        PEdump.logger.error "[!] non-zero dos stub after rich_hdr: #{t.inspect}"
        return nil
      end
      RichHdr.new(stub[start_idx, end_idx-start_idx]).tap do |x|
        x.key = key
        x.offset = stub.offset + start_idx
      end
    end

    def dexor
      self[4..-9].sub(/\A(#{Regexp::escape(key)}){3}/,'').xor(key)
    end

    def decode
      x = dexor
      if x.size%8 == 0
        x.unpack('vvV'*(x.size/8)).each_slice(3).map{ |slice| Entry.new(*slice)}
      else
        PEdump.logger.error "[?] #{self.class}: dexored size(#{x.size}) must be a multiple of 8"
        nil
      end
    end
  end

  class DOSStub < String
    attr_accessor :offset
  end

  def logger= l
    @logger = @@logger = l
  end

  def self.dump fname, params = {}
    new(fname, params).dump
  end

  def mz f=nil
    @mz ||= f && MZ.read(f).tap do |mz|
      if mz.signature != 'MZ' && mz.signature != 'ZM'
        if @force
          logger.warn  "[?] no MZ signature. want: 'MZ' or 'ZM', got: #{mz.signature.inspect}"
        else
          logger.error "[!] no MZ signature. want: 'MZ' or 'ZM', got: #{mz.signature.inspect}. (not forced)"
          return nil
        end
      end
    end
  end

  def dos_stub f=nil
    @dos_stub ||=
      begin
        return nil unless mz = mz(f)
        dos_stub_offset = mz.header_paragraphs.to_i * 0x10
        dos_stub_size   = mz.lfanew.to_i - dos_stub_offset
        if dos_stub_offset < 0
          logger.warn "[?] invalid DOS stub offset #{dos_stub_offset}"
          nil
        elsif f && dos_stub_offset > f.size
          logger.warn "[?] DOS stub offset beyond EOF: #{dos_stub_offset}"
          nil
        elsif dos_stub_size < 0
          logger.warn "[?] invalid DOS stub size #{dos_stub_size}"
          nil
        elsif dos_stub_size == 0
          # no DOS stub, it's ok
          nil
        elsif !f
          # no open file, it's ok
          nil
        else
          return nil if dos_stub_size == MZ::SIZE && dos_stub_offset == 0
          if dos_stub_size > 0x1000
            logger.warn "[?] DOS stub size too big (#{dos_stub_size}), limiting to 0x1000"
            dos_stub_size = 0x1000
          end
          f.seek dos_stub_offset
          DOSStub.new(f.read(dos_stub_size)).tap do |dos_stub|
            dos_stub.offset = dos_stub_offset
            if dos_stub['Rich']
              if @rich_hdr = RichHdr.from_dos_stub(dos_stub)
                dos_stub[dos_stub.index(@rich_hdr)..-1] = ''
              end
            end
          end
        end
      end
  end

  def rich_hdr f=nil
    dos_stub(f) && @rich_hdr
  end
  alias :rich_header :rich_hdr
  alias :rich        :rich_hdr

  def pe f=nil
    @pe ||=
      begin
        pe_offset = mz(f) && mz(f).lfanew
        if pe_offset.nil?
          logger.fatal "[!] NULL PE offset (e_lfanew). cannot continue."
          nil
        elsif pe_offset > f.size
          logger.fatal "[!] PE offset beyond EOF. cannot continue."
          nil
        else
          f.seek pe_offset
          PE.read f, :force => @force
        end
      end
  end

  def va2file va, h={}
    return nil if va.nil?

    sections.each do |s|
      if (s.VirtualAddress...(s.VirtualAddress+s.VirtualSize)).include?(va)
        return va - s.VirtualAddress + s.PointerToRawData
      end
    end

    # not found with regular search. assume any of VirtualSize was 0, and try with RawSize
    sections.each do |s|
      if (s.VirtualAddress...(s.VirtualAddress+s.SizeOfRawData)).include?(va)
        return va - s.VirtualAddress + s.PointerToRawData
      end
    end

    # still not found, bad/zero VirtualSizes & RawSizes ?

    # a special case - PE without sections
    return va if sections.empty?

    # check if only one section
    if sections.size == 1 || sections.all?{ |s| s.VirtualAddress.to_i == 0 }
      s = sections.first
      return va - s.VirtualAddress + s.PointerToRawData
    end

    # TODO: not all VirtualAdresses == 0 case

    logger.error "[?] can't find file_offset of VA 0x#{va.to_i.to_s(16)}" unless h[:quiet]
    nil
  end

  # OPTIONAL: assigns @mz, @rich_hdr, @pe, etc
  def dump f=nil
    f ? _dump_handle(f) : File.open(@fname,'rb'){ |f| _dump_handle(f) }
    self
  end

  def _dump_handle h
    return unless pe(h) # also calls mz(h)
    rich_hdr h
    resources h
    imports h   # also calls tls(h)
    exports h
    packer h
  end

  def data_directory f=nil
    pe(f) && pe.ioh && pe.ioh.DataDirectory
  end

  def sections f=nil
    pe(f) && pe.section_table
  end
  alias :section_table :sections

  ##############################################################################
  # imports
  ##############################################################################

  # http://sandsprite.com/CodeStuff/Understanding_imports.html
  # http://stackoverflow.com/questions/5631317/import-table-it-vs-import-address-table-iat
  IMAGE_IMPORT_DESCRIPTOR = create_struct 'V5',
    :OriginalFirstThunk,
    :TimeDateStamp,
    :ForwarderChain,
    :Name,
    :FirstThunk,
    # manual:
    :module_name,
    :original_first_thunk,
    :first_thunk

  ImportedFunction = Struct.new(:hint, :name, :ordinal)

  def imports f=nil
    return @imports if @imports
    return nil unless pe(f) && pe(f).ioh && f
    dir = @pe.ioh.DataDirectory[IMAGE_DATA_DIRECTORY::IMPORT]
    return [] if !dir || (dir.va == 0 && dir.size == 0)
    file_offset = va2file(dir.va)
    return nil unless file_offset

    # scan TLS first, to catch many fake imports trick from
    # http://code.google.com/p/corkami/source/browse/trunk/asm/PE/manyimportsW7.asm
    tls_aoi = nil
    if (tls = tls(f)) && tls.any?
      tls_aoi = tls.first.AddressOfIndex.to_i - @pe.ioh.ImageBase.to_i
      tls_aoi = tls_aoi > 0 ? va2file(tls_aoi) : nil
    end

    f.seek file_offset
    r = []
    while true
      if tls_aoi && tls_aoi == file_offset+16
        # catched the neat trick! :)
        # f.tell + 12  =  offset of 'FirstThunk' field from start of IMAGE_IMPORT_DESCRIPTOR structure
        logger.warn "[!] catched the 'imports terminator in TLS trick'"
        # http://code.google.com/p/corkami/source/browse/trunk/asm/PE/manyimportsW7.asm
        break
      end
      t=IMAGE_IMPORT_DESCRIPTOR.read(f)
      break if t.Name.to_i == 0 # also catches EOF
      r << t
      file_offset += IMAGE_IMPORT_DESCRIPTOR::SIZE
    end

    logger.warn "[?] non-empty last IMAGE_IMPORT_DESCRIPTOR: #{t.inspect}" unless t.empty?
    @imports = r.each do |x|
      if x.Name.to_i != 0 && (va = va2file(x.Name))
        f.seek va
        x.module_name = f.gets("\x00").chomp("\x00")
      end
      [:original_first_thunk, :first_thunk].each do |tbl|
        camel = tbl.capitalize.to_s.gsub(/_./){ |char| char[1..-1].upcase}
        if x[camel].to_i != 0 && (va = va2file(x[camel]))
          f.seek va
          x[tbl] ||= []
          if pe.x64?
            x[tbl] << t while (t = f.read(8).unpack('Q').first) != 0
          else
            x[tbl] << t while (t = f.read(4).unpack('V').first) != 0
          end
        end
        cache = {}
        bits = pe.x64? ? 64 : 32
        idx = -1
        x[tbl] && x[tbl].map! do |t|
          idx += 1
          cache[t] ||=
            if t & (2**(bits-1)) > 0                            # 0x8000_0000(_0000_0000)
              ImportedFunction.new(nil,nil,t & (2**(bits-1)-1)) # 0x7fff_ffff(_ffff_ffff)
            elsif va=va2file(t, :quiet => true)
              f.seek va
              if f.eof?
                logger.warn "[?] import va 0x#{va.to_s(16)} beyond EOF"
                nil
              else
                ImportedFunction.new(f.read(2).unpack('v').first, f.gets("\x00").chop)
              end
            elsif tbl == :original_first_thunk
              # OriginalFirstThunk entries can not be invalid, show a warning msg
              logger.warn "[?] invalid VA 0x#{t.to_s(16)} in #{camel}[#{idx}] for #{x.module_name}"
              nil
            elsif tbl == :first_thunk
              # FirstThunk entries can be invalid, so `info` msg only
              logger.info "[?] invalid VA 0x#{t.to_s(16)} in #{camel}[#{idx}] for #{x.module_name}"
              nil
            else
              raise "You are not supposed to be here! O_o"
            end
        end
        x[tbl] && x[tbl].compact!
      end
      if x.original_first_thunk && !x.first_thunk
        logger.warn "[?] import table: empty FirstThunk for #{x.module_name}"
      elsif !x.original_first_thunk && x.first_thunk
        logger.info "[?] import table: empty OriginalFirstThunk for #{x.module_name}"
      elsif x.original_first_thunk != x.first_thunk
        logger.debug "[?] import table: OriginalFirstThunk != FirstThunk for #{x.module_name}"
      end
    end
  end

  ##############################################################################
  # exports
  ##############################################################################

  #http://msdn.microsoft.com/en-us/library/ms809762.aspx
  IMAGE_EXPORT_DIRECTORY = create_struct 'V2v2V7',
    :Characteristics,
    :TimeDateStamp,
    :MajorVersion,          # These fields appear to be unused and are set to 0.
    :MinorVersion,          # These fields appear to be unused and are set to 0.
    :Name,
    :Base,                  # The starting ordinal number for exported functions
    :NumberOfFunctions,
    :NumberOfNames,
    :AddressOfFunctions,
    :AddressOfNames,
    :AddressOfNameOrdinals,
    # manual:
    :name, :entry_points, :names, :name_ordinals

  def exports f=nil
    return @exports if @exports
    return nil unless pe(f) && pe(f).ioh && f
    dir = @pe.ioh.DataDirectory[IMAGE_DATA_DIRECTORY::EXPORT]
    return nil if !dir || (dir.va == 0 && dir.size == 0)
    va = @pe.ioh.DataDirectory[IMAGE_DATA_DIRECTORY::EXPORT].va
    file_offset = va2file(va)
    return nil unless file_offset
    f.seek file_offset
    if f.eof?
      logger.info "[?] exports info beyond EOF"
      return nil
    end
    @exports = IMAGE_EXPORT_DIRECTORY.read(f).tap do |x|
      x.entry_points = []
      x.name_ordinals = []
      x.names = []
      if x.Name.to_i != 0 && (va = va2file(x.Name))
        f.seek va
        if f.eof?
          logger.warn "[?] export va 0x#{va.to_s(16)} beyond EOF"
          nil
        else
          x.name = f.gets("\x00").chomp("\x00")
        end
      end
      if x.NumberOfFunctions.to_i != 0
        if x.AddressOfFunctions.to_i !=0 && (va = va2file(x.AddressOfFunctions))
          f.seek va
          x.entry_points = []
          x.NumberOfFunctions.times do
            if f.eof?
              logger.warn "[?] got EOF while reading exports entry_points"
              break
            end
            x.entry_points << f.read(4).unpack('V').first
          end
        end
        if x.AddressOfNameOrdinals.to_i !=0 && (va = va2file(x.AddressOfNameOrdinals))
          f.seek va
          x.name_ordinals = []
          x.NumberOfNames.times do
            if f.eof?
              logger.warn "[?] got EOF while reading exports name_ordinals"
              break
            end
            x.name_ordinals << f.read(2).unpack('v').first + x.Base
          end
        end
      end
      if x.NumberOfNames.to_i != 0 && x.AddressOfNames.to_i !=0 && (va = va2file(x.AddressOfNames))
        f.seek va
        x.names = []
        x.NumberOfNames.times do
          if f.eof?
            logger.warn "[?] got EOF while reading exports names"
            break
          end
          x.names << f.read(4).unpack('V').first
        end
        x.names.map! do |va|
          f.seek va2file(va)
          f.gets("\x00").to_s.chomp("\x00")
        end
      end
    end
  end

  ##############################################################################
  # TLS
  ##############################################################################

  def tls f=nil
    @tls ||= pe(f) && pe(f).ioh && f &&
      begin
        dir = @pe.ioh.DataDirectory[IMAGE_DATA_DIRECTORY::TLS]
        return nil if !dir || dir.va == 0
        return nil unless file_offset = va2file(dir.va)
        f.seek file_offset
        if f.eof?
          logger.info "[?] TLS info beyond EOF"
          return nil
        end

        klass = @pe.x64? ? IMAGE_TLS_DIRECTORY64 : IMAGE_TLS_DIRECTORY32
        nEntries = [1,dir.size / klass.const_get('SIZE')].max
        r = []
        nEntries.times do
          break if f.eof? || !(entry = klass.read(f))
          r << entry
        end
        r
      end
  end

  ##############################################################################
  # resources
  ##############################################################################

  def resources f=nil
    @resources ||= _scan_resources(f)
  end

  def version_info f=nil
    resources(f) && resources(f).find_all{ |res| res.type == 'VERSION' }.map(&:data).flatten
  end

  ##############################################################################
  # packer / compiler detection
  ##############################################################################

  def packer f = nil
    @packer ||= pe(f) && @pe.ioh &&
      begin
        if !(va=@pe.ioh.AddressOfEntryPoint)
          logger.error "[?] can't find EntryPoint RVA"
          nil
        elsif va == 0 && @pe.dll?
          logger.debug "[.] it's a DLL with no EntryPoint"
          nil
        elsif !(ofs = va2file(va))
          logger.error "[?] can't find EntryPoint RVA (0x#{va.to_s(16)}) file offset"
          nil
        else
          require 'pedump/packer'
          if PEdump::Packer.all.size == 0
            logger.error "[?] no packer definitions found"
            nil
          else
            Packer.of f, :ep_offset => ofs
          end
        end
      end
  end
  alias :packers :packer
end

####################################################################################

if $0 == __FILE__
  require 'pp'
  dump = PEdump.new(ARGV.shift).dump
  if ARGV.any?
    ARGV.each do |arg|
      if dump.respond_to?(arg)
        pp dump.send(arg)
      elsif arg == 'restore_bitmaps'
        File.open(dump.fname,"rb") do |fi|
          r = dump.resources.
            find_all{ |r| %w'ICON BITMAP CURSOR'.include?(r.type) }.
            each do |r|
              fname = r.name.tr("/# ",'_')+".bmp"
              puts "[.] #{fname}"
              File.open(fname,"wb"){ |fo| fo << r.restore_bitmap(fi) }
              if mask = r.bitmap_mask(fi)
                fname.sub! '.bmp', '.mask.bmp'
                puts "[.] #{fname}"
                File.open(fname,"wb"){ |fo| fo << r.bitmap_mask(fi) }
              end
            end
        end
        exit
      else
        puts "[?] invalid arg #{arg.inspect}"
      end
    end
    exit
  end
  p dump.mz
  require './lib/hexdump_helper' if File.exist?("lib/hexdump_helper.rb")
  if defined?(HexdumpHelper)
    include HexdumpHelper
    puts hexdump(dump.dos_stub) if dump.dos_stub
    puts
    if dump.rich_hdr
      puts hexdump(dump.rich_hdr)
      puts
      p(dump.rich_hdr.decode)
      puts hexdump(dump.rich_hdr.dexor)
    end
  end
  pp dump.pe
  pp dump.resources
end
