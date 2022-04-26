-------------------------------------------------------------------------------
-- File       : Application.vhd
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- This file is part of 'Camera link gateway'.
-- It is subject to the license terms in the LICENSE.txt file found in the
-- top-level directory of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of 'Camera link gateway', including this file,
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
use surf.Pgp4Pkg.all;
use surf.SsiPkg.all;

library axi_pcie_core;
use axi_pcie_core.AxiPciePkg.all;
use axi_pcie_core.MigPkg.all;

library work;
use work.AppMigPkg.all;

entity DdrApplication is
   generic (
      TPD_G             : time             := 1 ns;
      AXI_BASE_ADDR_G   : slv(31 downto 0) := x"00C0_0000";
      DMA_AXIS_CONFIG_G : AxiStreamConfigType;
      NUM_LANES_G       : positive);
   port (
      -- AXI-Lite Interface
      axilClk               : in  sl;
      axilRst               : in  sl;
      axilReadMaster        : in  AxiLiteReadMasterType;
      axilReadSlave         : out AxiLiteReadSlaveType;
      axilWriteMaster       : in  AxiLiteWriteMasterType;
      axilWriteSlave        : out AxiLiteWriteSlaveType;
      -- PGP Streams (axilClk domain)
      pgpIbMasters          : out AxiStreamMasterArray(NUM_LANES_G-1 downto 0);
      pgpIbSlaves           : in  AxiStreamSlaveArray(NUM_LANES_G-1 downto 0);
      pgpObMasters          : in  AxiStreamQuadMasterArray(NUM_LANES_G-1 downto 0);
      pgpObSlaves           : out AxiStreamQuadSlaveArray(NUM_LANES_G-1 downto 0);
      -- Trigger Event streams (axilClk domain)
      eventTrigMsgMasters   : in  AxiStreamMasterArray(NUM_LANES_G-1 downto 0);
      eventTrigMsgSlaves    : out AxiStreamSlaveArray(NUM_LANES_G-1 downto 0);
      eventTrigMsgCtrl      : out AxiStreamCtrlArray(NUM_LANES_G-1 downto 0);
      eventTimingMsgMasters : in  AxiStreamMasterArray(NUM_LANES_G-1 downto 0);
      eventTimingMsgSlaves  : out AxiStreamSlaveArray(NUM_LANES_G-1 downto 0);
      -- DMA Interface (dmaClk domain)
      dmaClk                : in  sl;
      dmaRst                : in  sl;
      dmaIbMasters          : out AxiStreamMasterArray(NUM_LANES_G downto 0);
      dmaIbSlaves           : in  AxiStreamSlaveArray(NUM_LANES_G downto 0);
      dmaObMasters          : in  AxiStreamMasterArray(NUM_LANES_G downto 0);
      dmaObSlaves           : out AxiStreamSlaveArray(NUM_LANES_G downto 0);
      -- DDR Ports
      clk200       : in    sl;
      rst200       : in    sl;
      ddrClkP      : in    slv          (1 downto 0);
      ddrClkN      : in    slv          (1 downto 0);
      ddrOut       : out   DdrOutArray  (1 downto 0);
      ddrInOut     : inout DdrInOutArray(1 downto 0) );
end DdrApplication;

architecture mapping of DdrApplication is

   constant MIGTPCI_INDEX_C : integer := NUM_LANES_G;
   constant AXIL_CONFIG_C : AxiLiteCrossbarMasterConfigArray(NUM_LANES_G downto 0) := genAxiLiteConfig(NUM_LANES_G+1, AXI_BASE_ADDR_G, 22, 19);

   signal axilWriteMasters : AxiLiteWriteMasterArray(NUM_LANES_G downto 0);
   signal axilWriteSlaves  : AxiLiteWriteSlaveArray(NUM_LANES_G downto 0);
   signal axilReadMasters  : AxiLiteReadMasterArray(NUM_LANES_G downto 0);
   signal axilReadSlaves   : AxiLiteReadSlaveArray(NUM_LANES_G downto 0);

   signal appClk           : slv(NUM_LANES_G-1 downto 0);
   signal appRst           : slv(NUM_LANES_G-1 downto 0);
   signal appIbMasters     : AxiStreamMasterArray(NUM_LANES_G-1 downto 0);
   signal appIbSlaves      : AxiStreamSlaveArray(NUM_LANES_G-1 downto 0);
   signal appObMasters     : AxiStreamMasterArray(NUM_LANES_G-1 downto 0);
   signal appObSlaves      : AxiStreamSlaveArray(NUM_LANES_G-1 downto 0);
   signal appIbAlmostFull  : slv(NUM_LANES_G-1 downto 0) := (others=>'0');
   signal appIbFull        : slv(NUM_LANES_G-1 downto 0) := (others=>'0');
   
   signal memReady         : slv                (1 downto 0);
   signal memWriteMasters  : AxiWriteMasterArray(NUM_LANES_G-1 downto 0);
   signal memWriteSlaves   : AxiWriteSlaveArray (NUM_LANES_G-1 downto 0);
   signal memReadMasters   : AxiReadMasterArray (NUM_LANES_G-1 downto 0);
   signal memReadSlaves    : AxiReadSlaveArray  (NUM_LANES_G-1 downto 0);
   signal amemWriteMasters : AxiWriteMasterArray(7 downto 0) := (others=>AXI_WRITE_MASTER_INIT_C);
   signal amemWriteSlaves  : AxiWriteSlaveArray (7 downto 0) := (others=>AXI_WRITE_SLAVE_INIT_C);
   signal amemReadMasters  : AxiReadMasterArray (7 downto 0) := (others=>AXI_READ_MASTER_INIT_C);
   signal amemReadSlaves   : AxiReadSlaveArray  (7 downto 0) := (others=>AXI_READ_SLAVE_INIT_C);

   signal rdDescReq        : AxiReadDmaDescReqArray(NUM_LANES_G-1 downto 0);
   signal rdDescRet        : AxiReadDmaDescRetArray(NUM_LANES_G-1 downto 0);
   signal rdDescReqAck     : slv(NUM_LANES_G-1 downto 0);
   signal rdDescRetAck     : slv(NUM_LANES_G-1 downto 0);

   signal mtpIbMasters     : AxiStreamMasterArray   (NUM_LANES_G downto 0);
   signal mtpIbSlaves      : AxiStreamSlaveArray    (NUM_LANES_G downto 0);

   signal migConfig        : MigConfigArray(NUM_LANES_G-1 downto 0) := (others=>MIG_CONFIG_INIT_C);
   signal migStatus        : MigStatusArray(NUM_LANES_G-1 downto 0);

   signal userReset        : sl;
   signal arst200, irst200, urst200 : sl;

   constant AXIO_STREAM_CONFIG_C : AxiStreamConfigType := ssiAxiStreamConfig(16, TKEEP_COMP_C, TUSER_FIRST_LAST_C, 8, 2);  -- 128-bit interface
     
begin

    -- Forcing BUFG for reset that's used everywhere      
    U_BUFG : BUFG
      port map (
        I => rst200,
        O => arst200);
    
    irst200 <= rst200 or userReset;
    -- Forcing BUFG for reset that's used everywhere      
    U_BUFGU : BUFG
      port map (
        I => irst200,
        O => urst200);
  
   --------------------
   -- AXI-Lite Crossbar
   --------------------
   U_AXIL_XBAR : entity surf.AxiLiteCrossbar
      generic map (
         TPD_G              => TPD_G,
         NUM_SLAVE_SLOTS_G  => 1,
         NUM_MASTER_SLOTS_G => NUM_LANES_G+1,
         MASTERS_CONFIG_G   => AXIL_CONFIG_C)
      port map (
         axiClk              => axilClk,
         axiClkRst           => axilRst,
         sAxiWriteMasters(0) => axilWriteMaster,
         sAxiWriteSlaves(0)  => axilWriteSlave,
         sAxiReadMasters(0)  => axilReadMaster,
         sAxiReadSlaves(0)   => axilReadSlave,
         mAxiWriteMasters    => axilWriteMasters,
         mAxiWriteSlaves     => axilWriteSlaves,
         mAxiReadMasters     => axilReadMasters,
         mAxiReadSlaves      => axilReadSlaves);

   -------------------
   -- DdrApplication Lane
   -------------------
   GEN_VEC :
   for i in NUM_LANES_G-1 downto 0 generate
      U_Lane : entity work.AppLane
         generic map (
            TPD_G             => TPD_G,
            AXI_BASE_ADDR_G   => AXIL_CONFIG_C(i).baseAddr,
            DMA_AXIS_CONFIG_G => PGP4_AXIS_CONFIG_C)
         port map (
            -- AXI-Lite Interface (axilClk domain)
            axilClk              => axilClk,
            axilRst              => axilRst,
            axilReadMaster       => axilReadMasters(i),
            axilReadSlave        => axilReadSlaves(i),
            axilWriteMaster      => axilWriteMasters(i),
            axilWriteSlave       => axilWriteSlaves(i),
            -- PGP Streams (axilClk domain)
            pgpIbMaster          => pgpIbMasters(i),
            pgpIbSlave           => pgpIbSlaves(i),
            pgpObMasters         => pgpObMasters(i),
            pgpObSlaves          => pgpObSlaves(i),
            -- Trigger Event streams (axilClk domain)
            eventTrigMsgMaster   => eventTrigMsgMasters(i),
            eventTrigMsgSlave    => eventTrigMsgSlaves(i),
            eventTimingMsgMaster => eventTimingMsgMasters(i),
            eventTimingMsgSlave  => eventTimingMsgSlaves(i),
            -- DMA Interface (dmaClk domain)
            dmaClk               => appClk(i),
            dmaRst               => appRst(i),
            dmaIbMaster          => appIbMasters(i),
            dmaIbSlave           => appIbSlaves(i),
            dmaObMaster          => appObMasters(i),
            dmaObSlave           => appObSlaves(i));

      appClk      (i) <= axilClk;
      appRst      (i) <= axilRst;

      eventTrigMsgCtrl(i).pause <= appIbAlmostFull(i);
      
      U_HwDma : entity work.AppToMigDma
        generic map ( AXI_BASE_ADDR_G     => (toSlv(i,2) & toSlv(0,30)),
                      SLAVE_AXIS_CONFIG_G => PGP4_AXIS_CONFIG_C,
                      MIG_AXIS_CONFIG_G   => AXIO_STREAM_CONFIG_C )
        port map ( sAxisClk        => appClk         (i),
                   sAxisRst        => appRst         (i),
                   sAxisMaster     => appIbMasters   (i),
                   sAxisSlave      => appIbSlaves    (i),
                   sAlmostFull     => appIbAlmostFull(i),
                   sFull           => appIbFull      (i),
                   mAxiClk         => clk200,
                   mAxiRst         => urst200,
                   mAxiWriteMaster => memWriteMasters(i),
                   mAxiWriteSlave  => memWriteSlaves (i),
                   rdDescReq       => rdDescReq      (i), -- exchange
                   rdDescReqAck    => rdDescReqAck   (i),
                   rdDescRet       => rdDescRet      (i),
                   rdDescRetAck    => rdDescRetAck   (i),
                   memReady        => memReady       (i mod 2),
                   config          => migConfig      (i),
                   status          => migStatus      (i) );
      U_ObFifo : entity surf.AxiStreamFifoV2
        generic map ( FIFO_ADDR_WIDTH_G   => 4,
                      SLAVE_AXI_CONFIG_G  => DMA_AXIS_CONFIG_G,
                      MASTER_AXI_CONFIG_G => PGP4_AXIS_CONFIG_C )
        port map ( sAxisClk    => dmaClk,
                   sAxisRst    => dmaRst,
                   sAxisMaster => dmaObMasters(i),
                   sAxisSlave  => dmaObSlaves (i),
                   sAxisCtrl   => open,
                   mAxisClk    => appClk      (i),
                   mAxisRst    => appRst      (i),
                   mAxisMaster => appObMasters(i),
                   mAxisSlave  => appObSlaves (i) );
      
   end generate GEN_VEC;

  U_Mig2Pcie : entity work.MigToPcieDma
       generic map ( LANES_G           => NUM_LANES_G,
                     MONCLKS_G         => 4,
                     AXIS_CONFIG_G     => AXIO_STREAM_CONFIG_C,
                     DEBUG_G           => false )
--                     DEBUG_G          => (i<1) )
       port map ( axiClk          => clk200,
                  axiRst          => arst200,
                  usrRst          => userReset,
                  axiReadMasters  => memReadMasters,
                  axiReadSlaves   => memReadSlaves ,
                  rdDescReq       => rdDescReq     ,
                  rdDescAck       => rdDescReqAck  ,
                  rdDescRet       => rdDescRet     ,
                  rdDescRetAck    => rdDescRetAck  ,
                  axisMasters     => mtpIbMasters  ,
                  axisSlaves      => mtpIbSlaves   ,
                  axilClk         => axilClk,
                  axilRst         => axilRst,
                  axilWriteMaster => axilWriteMasters(MIGTPCI_INDEX_C),
                  axilWriteSlave  => axilWriteSlaves (MIGTPCI_INDEX_C),
                  axilReadMaster  => axilReadMasters (MIGTPCI_INDEX_C),
                  axilReadSlave   => axilReadSlaves  (MIGTPCI_INDEX_C),
                  monClk(0)       => axilClk,
                  monClk(1)       => dmaClk ,
                  monClk(2)       => clk200         ,
                  monClk(3)       => clk200         ,
                  migConfig       => migConfig      ,
                  migStatus       => migStatus      );

    GEN_DMAIB : for j in 0 to NUM_LANES_G generate
      U_IbFifo : entity surf.AxiStreamFifoV2
         generic map (
            -- General Configurations
            INT_PIPE_STAGES_G   => 1,
            PIPE_STAGES_G       => 1,
            -- FIFO configurations
            FIFO_ADDR_WIDTH_G   => 4,
            -- AXI Stream Port Configurations
            SLAVE_AXI_CONFIG_G  => AXIO_STREAM_CONFIG_C,
            MASTER_AXI_CONFIG_G => DMA_AXIS_CONFIG_G)
         port map (
            -- Slave Port
            sAxisClk    => clk200,
            sAxisRst    => arst200,
            sAxisMaster => mtpIbMasters(j),
            sAxisSlave  => mtpIbSlaves (j),
            -- Master Port
            mAxisClk    => dmaClk,
            mAxisRst    => dmaRst,
            mAxisMaster => dmaIbMasters(j),
            mAxisSlave  => dmaIbSlaves (j));
    end generate;

    gen_mem : process (memWriteMasters, amemWriteSlaves, memReadMasters, amemReadSlaves) is
       variable i, j : integer;
       variable v : slv(2 downto 0);
    begin
      for i in 0 to NUM_LANES_G-1 loop
        v := toSlv(i,3);
        j := conv_integer( v(0) & v(2 downto 1) ); 
        amemWriteMasters(j) <= memWriteMasters (i);
        memWriteSlaves  (i) <= amemWriteSlaves (j);
        amemReadMasters (j) <= memReadMasters  (i);
        memReadSlaves   (i) <= amemReadSlaves  (j);
      end loop;
    end process gen_mem;
     
   U_MIG0 : entity work.MigA
     generic map (
       MASTERS_G    => 4 )
    port map ( axiReady        => memReady(0),
               --
               axiClk          => clk200,
               axiRst          => arst200,
               axiWriteMasters => amemWriteMasters(3 downto 0),
               axiWriteSlaves  => amemWriteSlaves (3 downto 0),
               axiReadMasters  => amemReadMasters (3 downto 0),
               axiReadSlaves   => amemReadSlaves  (3 downto 0),
               --
               ddrClkP         => ddrClkP (0),
               ddrClkN         => ddrClkN (0),
               ddrOut          => ddrOut  (0),
               ddrInOut        => ddrInOut(0) );

  U_MIG1 : entity work.MigB
     generic map (
       MASTERS_G    => 4 )
    port map ( axiReady        => memReady(1),
               --
               axiClk          => clk200,
               axiRst          => arst200,
               axiWriteMasters => amemWriteMasters(7 downto 4),
               axiWriteSlaves  => amemWriteSlaves (7 downto 4),
               axiReadMasters  => amemReadMasters (7 downto 4),
               axiReadSlaves   => amemReadSlaves  (7 downto 4),
               --
               ddrClkP         => ddrClkP (1),
               ddrClkN         => ddrClkN (1),
               ddrOut          => ddrOut  (1),
               ddrInOut        => ddrInOut(1) );
  
end mapping;
