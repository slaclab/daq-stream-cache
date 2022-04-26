-------------------------------------------------------------------------------
-- File       : AppToMigWrapper.vhd
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2017-03-06
-- Last update: 2022-03-18
-------------------------------------------------------------------------------
-- Description: Wrapper for Xilinx Axi Data Mover
-- Axi stream input (dscReadMasters.command) launches an AxiReadMaster to
-- read from a memory mapped device and write to another memory mapped device
-- with an AxiWriteMaster to a start address given by the AxiLite bus register
-- writes.  Completion of the transfer results in another axi write.
-------------------------------------------------------------------------------
-- This file is part of 'axi-pcie-core'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'axi-pcie-core', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;


library surf;
use surf.StdRtlPkg.all;
use surf.AxiPkg.all;
use surf.AxiLitePkg.all;
use surf.AxiStreamPkg.all;
use surf.AxiDmaPkg.all;
use work.AppMigPkg.all;

entity AppToMigDma is
  generic ( AXI_BASE_ADDR_G     : slv(31 downto 0) := (others=>'0');
            MIG_AXIS_CONFIG_G   : AxiStreamConfigType;
            SLAVE_AXIS_CONFIG_G : AxiStreamConfigType;
            DEBUG_G             : boolean          := false );
  port    ( -- Clock and reset
    sAxisClk         : in  sl; -- 156MHz
    sAxisRst         : in  sl;
    sAxisMaster      : in  AxiStreamMasterType;
    sAxisSlave       : out AxiStreamSlaveType ;
    sAlmostFull      : out sl;
    sFull            : out sl;
    -- AXI4 Interface to MIG
    mAxiClk          : in  sl; -- 200MHz
    mAxiRst          : in  sl;
    mAxiWriteMaster  : out AxiWriteMasterType ;
    mAxiWriteSlave   : in  AxiWriteSlaveType  ;
    -- Command/Status to MigToPcieDma
    rdDescReq        : out AxiReadDmaDescReqType;
    rdDescReqAck     : in  sl;
    rdDescRet        : in  AxiReadDmaDescRetType;
    rdDescRetAck     : out sl;
    -- Configuration
    memReady         : in  sl := '0';
    config           : in  MigConfigType;
    -- Status
    status           : out MigStatusType );
end AppToMigDma;

architecture mapping of AppToMigDma is

  signal mAxisMaster : AxiStreamMasterType;
  signal mAxisSlave  : AxiStreamSlaveType;

  signal doutTransfer  : slv(AXI_WRITE_DMA_DESC_RET_SIZE_C-1 downto 0);
  
  signal mPause  : sl;
  signal mFull   : sl;

  type TagState is (IDLE_T, REQUESTED_T, COMPLETED_T);
  type TagStateArray is array(natural range<>) of TagState;
  
  constant BIS : integer := BLOCK_INDEX_SIZE_C;
  
  type RegType is record
    wrIndex        : slv(BIS-1 downto 0);  -- write request
    wcIndex        : slv(BIS-1 downto 0);  -- write complete
    rdIndex        : slv(BIS-1 downto 0);  -- read complete
    wrTag          : TagStateArray(15 downto 0);
    wrTransfer     : sl;
    wrTransferAddr : slv(BIS-1 downto 0);
    wrTransferDin  : slv(AXI_WRITE_DMA_DESC_RET_SIZE_C-1 downto 0);
    rdenb          : sl;
    wrDescAck      : AxiWriteDmaDescAckType;
    wrDescRetAck   : sl;
    rdDescReq      : AxiReadDmaDescReqType;
    rdDescRetAck   : sl;
    blocksFree     : slv(BIS-1 downto 0);
    wid            : slv(7 downto 0);
    wdest          : slv(7 downto 0);
    rid            : slv(7 downto 0);
    rdest          : slv(7 downto 0);
    writeQueCnt    : slv(7 downto 0);
  end record;

  constant REG_INIT_C : RegType := (
    wrIndex        => (others=>'0'),
    wcIndex        => (others=>'0'),
    rdIndex        => (others=>'0'),
    wrTag          => (others=>IDLE_T),
    wrTransfer     => '0',
    wrTransferAddr => (others=>'0'),
    wrTransferDin  => (others=>'0'),
    rdenb          => '0',
    wrDescAck      => AXI_WRITE_DMA_DESC_ACK_INIT_C,
    wrDescRetAck   => '0',
    rdDescReq      => AXI_READ_DMA_DESC_REQ_INIT_C,
    rdDescRetAck   => '0',
    blocksFree     => (others=>'0'),
    wid            => (others=>'1'),
    wdest          => (others=>'1'),
    rid            => (others=>'1'),
    rdest          => (others=>'1'),
    writeQueCnt    => (others=>'0'));

  signal r   : RegType := REG_INIT_C;
  signal rin : RegType;

  signal isAxisSlave : AxiStreamSlaveType;
  signal isPause     : sl;
  signal isFull      : sl;
  
  signal rdenb          : sl;
  signal rdTransferAddr : slv(BIS-1 downto 0);  -- read complete

  signal wrDescReq    : AxiWriteDmaDescReqType;
  signal wrDescAck    : AxiWriteDmaDescAckType;
  signal wrDescRet    : AxiWriteDmaDescRetType;
  signal wrDescRetAck : sl;

begin

  sAxisSlave                <= isAxisSlave;
  sAlmostFull               <= isPause;
  sFull                     <= isFull;
  
  mPause <= '1' when (r.blocksFree < config.blocksPause) else '0';
  mFull  <= '1' when ((r.blocksFree < 4) or (config.inhibit='1')) else '0';

  U_Pause : entity surf.Synchronizer
    port map ( clk     => sAxisClk,
               rst     => sAxisRst,
               dataIn  => mPause,
               dataOut => isPause );

  U_Full : entity surf.Synchronizer
    port map ( clk     => sAxisClk,
               rst     => sAxisRst,
               dataIn  => mFull,
               dataOut => isFull );

  U_Ready : entity surf.Synchronizer
    port map ( clk     => mAxiClk,
               rst     => mAxiRst,
               dataIn  => memReady,
               dataOut => status.memReady );

  U_AxisFifo : entity surf.AxiStreamFifoV2
    generic map ( FIFO_ADDR_WIDTH_G   => 8,
                  SLAVE_AXI_CONFIG_G  => SLAVE_AXIS_CONFIG_G,
                  MASTER_AXI_CONFIG_G => MIG_AXIS_CONFIG_G )
    port map ( sAxisClk    => sAxisClk,
               sAxisRst    => sAxisRst,
               sAxisMaster => sAxisMaster,
               sAxisSlave  => isAxisSlave,
               sAxisCtrl   => open,
               mAxisClk    => mAxiClk,
               mAxisRst    => mAxiRst,
               mAxisMaster => mAxisMaster,
               mAxisSlave  => mAxisSlave );

  U_DmaWrite : entity surf.AxiStreamDmaV2Write
    generic map ( AXI_READY_EN_G => true,
                  AXIS_CONFIG_G  => MIG_AXIS_CONFIG_G,
                  AXI_CONFIG_G   => APP2MIG_AXI_CONFIG_C )
    port map ( axiClk         => mAxiClk,
               axiRst         => mAxiRst,
               dmaWrDescReq   => wrDescReq,
               dmaWrDescAck   => wrDescAck,
               dmaWrDescRet   => wrDescRet,
               dmaWrDescRetAck=> wrDescRetAck,
               axiCache       => x"3",
               axisMaster     => mAxisMaster,
               axisSlave      => mAxisSlave,
               axiWriteMaster => mAxiWriteMaster,
               axiWriteSlave  => mAxiWriteSlave );
                    
  U_TransferFifo : entity surf.SimpleDualPortRam
    generic map ( DATA_WIDTH_G => AXI_WRITE_DMA_DESC_RET_SIZE_C,
                  ADDR_WIDTH_G => BIS )
    port map ( clka       => mAxiClk,
               wea        => r.wrTransfer,
               addra      => r.wrTransferAddr,
               dina       => r.wrTransferDin,
               clkb       => mAxiClk,
               enb        => rdenb,
               addrb      => rdTransferAddr,
               doutb      => doutTransfer );

  comb : process ( r, mAxiRst,
                   mAxisMaster, mAxisSlave,
                   wrDescReq,
                   wrDescRet,
                   rdDescReqAck,
                   rdDescRet,
                   doutTransfer ) is
    variable v       : RegType;
    variable i       : integer;
    variable wlen    : slv(22 downto 0);
    variable waddr   : slv(31 downto 0);
    variable rlen    : slv(22 downto 0);
    variable raddr   : slv(31 downto 0);
    variable stag    : slv( 3 downto 0);
    variable itag    : integer;
    variable axiRstQ : slv( 2 downto 0) := (others=>'1');
    variable dmaDesc : AxiWriteDmaDescRetType;
  begin
    v := r;

    dmaDesc := toAxiWriteDmaDescRet(doutTransfer,'1');
    
    v.wrTransfer               := '0';
    
    i := BLOCK_BASE_SIZE_C;
    
    if (wrDescReq.valid = '0') then
      v.wrDescAck.valid := '0';
    end if;

    if (wrDescRet.valid = '0') then
      v.wrDescRetAck := '0';
    end if;
    
    itag := conv_integer(r.wrIndex(3 downto 0));
    if (wrDescReq.valid = '1' and r.wrDescAck.valid = '0') then
      waddr   := resize(r.wrIndex & toSlv(0,i), 32) + AXI_BASE_ADDR_G;
      wlen    := (others=>'0');
      wlen(i) := '1';
      v.wrDescAck.address := resize(waddr,64);
      v.wrDescAck.dropEn  := '0';
      v.wrDescAck.maxSize := resize(wlen,32);
      v.wrDescAck.contEn  := '1';
      v.wrDescAck.buffId  := toSlv(itag,32);
      if (r.wrTag(itag) = IDLE_T and
          resize(r.wrIndex + 16,BIS) /= r.rdIndex) then  -- prevent overwrite
        v.wrIndex                  := r.wrIndex + 1;
        v.wrTag(itag)              := REQUESTED_T;
        v.wrDescAck.valid          := '1';
        v.wid                      := resize(wrDescReq.id,8);
        v.wdest                    := resize(wrDescReq.dest,8);
      end if;
    end if;

    stag := wrDescRet.buffId(3 downto 0);
    itag := conv_integer(stag);
    if (wrDescRet.valid = '1' and r.wrDescRetAck = '0') then
      v.wrDescRetAck     := '1';
      v.wrTag(itag)      := COMPLETED_T;
      v.wrTransfer       := '1';
      v.wrTransferDin    := toSlv(wrDescRet);
      if stag < r.wcIndex(3 downto 0) then
        v.wrTransferAddr := (r.wcIndex(BIS-1 downto 4)+1) & stag;
      else
        v.wrTransferAddr := (r.wcIndex(BIS-1 downto 4)+0) & stag;
      end if;
    end if;
    
    itag := conv_integer(r.wcIndex(3 downto 0));
    if r.wrTag(itag) = COMPLETED_T then
      v.wrTag(itag) := IDLE_T;
      v.wcIndex     := r.wcIndex + 1;
    end if;

    if rdDescReqAck='1' then
      v.rdDescReq.valid := '0';
    end if;
    
    if (v.rdDescReq.valid='0' and
        r.rdenb ='1' and
        r.rdIndex /= r.wcIndex) then
      raddr   := resize(r.rdIndex & toSlv(0,i), 32) + AXI_BASE_ADDR_G;
      rlen                       := resize(dmaDesc.size,rlen'length);
      v.rdDescReq.valid          := '1';
      v.rdDescReq.address        := resize(raddr,64);
      v.rdDescReq.size           := resize(rlen,32);
      v.rdDescReq.buffId         := resize(r.rdIndex,32);
      v.rdDescReq.firstUser      := dmaDesc.firstUser;
      v.rdDescReq.lastUser       := dmaDesc.lastUser;
      v.rdDescReq.continue       := dmaDesc.continue;
      v.rdDescReq.id             := dmaDesc.id;
      v.rdDescReq.dest           := dmaDesc.dest;
      v.rid                      := dmaDesc.id;
      v.rdest                    := dmaDesc.dest;
      v.rdIndex                  := r.rdIndex + 1;
    end if;

    if (r.wrTransfer = '1' and
        r.wrTransferAddr = v.rdIndex) then
      v.rdenb := '0';
    else
      v.rdenb := '1';
    end if;

    if (rdDescRet.valid = '0') then
      v.rdDescRetAck := '0';
    end if;
    
    if (rdDescRet.valid = '1' and r.rdDescRetAck = '0') then
      v.rdDescRetAck := '1';
      v.writeQueCnt  := v.writeQueCnt + 1;
    end if;

    v.blocksFree              := resize(r.rdIndex - r.wcIndex - 1, BIS);

    status.blocksFree         <= r.blocksFree;
    status.blocksQueued       <= resize(r.wrIndex - r.rdIndex, BIS);
    status.writeQueCnt        <= r.writeQueCnt;
    status.wrIndex            <= r.wrIndex;
    status.wcIndex            <= r.wcIndex;
    status.rdIndex            <= r.rdIndex;
    
    status.wid                <= r.wid;
    status.wdest              <= r.wdest;
    status.rid                <= r.rid;
    status.rdest              <= r.rdest;

    wrDescAck                 <= r.wrDescAck;
    wrDescRetAck              <= r.wrDescRetAck;
    rdDescReq                 <= r.rdDescReq;
    rdDescRetAck              <= r.rdDescRetAck;

    rdenb          <= v.rdenb;
    rdTransferAddr <= v.rdIndex;
    
    if axiRstQ(0) = '1' then
      v := REG_INIT_C;
    end if;
    
    rin <= v;

    axiRstQ := mAxiRst & axiRstQ(2 downto 1);
    
  end process comb;

  seq: process(mAxiClk) is
  begin
    if rising_edge(mAxiClk) then
      r <= rin;
    end if;
  end process seq;

end mapping;
