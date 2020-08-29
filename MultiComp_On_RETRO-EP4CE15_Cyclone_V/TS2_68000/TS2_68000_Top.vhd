-- Jeff Tranter's TS2 in an FPGA
--		https://jefftranter.blogspot.com/2017/01/building-68000-single-board-computer_14.html
-- 68K CPU Core Copyright (c) 2009-2013 Tobias Gubener
-- Documented on Hackaday at:
--		https://hackaday.io/project/173678-retro-68000-cpu-in-an-fpga
-- Baseboard is
--		http://land-boards.com/blwiki/index.php?title=RETRO-EP4CE15
-- FPGA board is
--		http://land-boards.com/blwiki/index.php?title=QM_Tech_Cyclone_V_FPGA_Board
-- The main features are:
--		M68000 CPU
--			16.7 MHz
--			24-bit address space
--		ROM Monitors
--			ROM Space reserved 0x008000-0x00FFFF
--			Teeside TS2BUG 3KB 0x008000-0x00BFFF (16KB used), or
--			MECB TUTOR 16KB Monitor ROMs 0x008000-0x00BFFF (16KB used)
--		Internal SRAM
--			32KB Internal SRAM 0x000000-0x007FFF
--			64KB Internal SRAM 0x200000-0x20FFFF
--			32KB Internal SRAM 0x210000-0x217FFF
-- 	1 MB External SRAM 0x300000-0x3FFFFF (byte addressible only)
--		ANSI Video Display Unit (VDU)
--			VGA and PS/2
--		6850 ACIA UART - USB to Serial
--			ACIASTAT	= 0x010041
--			ACIADATA	= 0x010043
--		DC power options
--			USB
---		DC Jack on FPGA board
--
-- Doug Gilliland 2020
--

library ieee;
use ieee.std_logic_1164.all;
use  IEEE.STD_LOGIC_ARITH.all;
use  IEEE.STD_LOGIC_UNSIGNED.all;

entity TS2_68000_Top is
	port(
		i_CLOCK_50	: in std_logic;
		n_reset		: in std_logic;
		
		rxd1			: in std_logic := '1';		-- Hardware Handshake needed
		txd1			: out std_logic;
		cts1			: in std_logic := '1';
		rts1			: out std_logic;
		serSelect	: in std_logic := '1';		-- Jumper with pullup in FPGA for selecting serial between ACIA (installed) and VDU (removed)
		
		videoR0		: out std_logic := '1';
		videoG0		: out std_logic := '1';
		videoB0		: out std_logic := '1';
		videoR1		: out std_logic := '1';
		videoG1		: out std_logic := '1';
		videoB1		: out std_logic := '1';
		hSync			: out std_logic := '1';
		vSync			: out std_logic := '1';

		ps2Clk		: inout std_logic;
		ps2Data		: inout std_logic;
		
		IO_PIN		: out std_logic_vector(48 downto 3);
		
		-- External SRAM Not used but assigning pins so it's not active
		sramData		: inout std_logic_vector(7 downto 0);
		sramAddress	: out std_logic_vector(19 downto 0);
		n_sRamWE		: out std_logic := '1';
		n_sRamCS		: out std_logic := '1';
		n_sRamOE		: out std_logic := '1';
		
		-- D RAM not used but making sure that it's not active
		n_sdRamCas	: out std_logic := '1';		-- CAS on schematic
		n_sdRamRas	: out std_logic := '1';		-- RAS
		n_sdRamWe	: out std_logic := '1';		-- SDWE
		n_sdRamCe	: out std_logic := '1';		-- SD_NCS0
		sdRamClk		: out std_logic := '1';		-- SDCLK0
		sdRamClkEn	: out std_logic := '1';		-- SDCKE0
		sdRamAddr	: out std_logic_vector(14 downto 0) := "000"&x"000";
		sdRamData	: in std_logic_vector(15 downto 0);
		
		-- SD Card not used but making sure that it's not active
		sdCS			: out std_logic := '1';
		sdMOSI		: out std_logic := '1';
		sdMISO		: in std_logic := '1';
		sdSCLK		: out std_logic := '1';
		driveLED		: out std_logic :='1'		-- D5 LED
	);
end TS2_68000_Top;

architecture struct of TS2_68000_Top is

	-- CPU Control signals
	signal cpuAddress					: std_logic_vector(31 downto 0);
	signal cpuDataOut					: std_logic_vector(15 downto 0);
	signal cpuDataIn					: std_logic_vector(15 downto 0);
	signal n_WR							: std_logic;
	signal w_nUDS      				: std_logic;
	signal w_nLDS      				: std_logic;
	signal w_busstate      			: std_logic_vector(1 downto 0);
	signal w_nResetOut      		: std_logic;
	signal w_FC      					: std_logic_vector(2 downto 0);
	signal w_clr_berr      			: std_logic;

	-- Interrupts from peripherals
	signal w_n_IRQ5					: std_logic :='1';	
	signal w_n_IRQ6					: std_logic :='1';	
	
	-- Chip Selects
	signal w_n_RomCS					: std_logic :='1';
	signal w_n_RamCS					: std_logic :='1';
	signal w_WrRamByteEn				: std_logic_vector(1 downto 0) := "00";
	signal w_wrRamStrobe				: std_logic :='0';
	signal w_n_Ram2CS					: std_logic :='1';
	signal w_WrRam2ByteEn			: std_logic_vector(1 downto 0) := "00";
	signal w_wrRam2Strobe			: std_logic :='0';
	signal w_n_Ram3CS					: std_logic :='1';
	signal w_WrRam3ByteEn			: std_logic_vector(1 downto 0) := "00";
	signal w_wrRam3Strobe			: std_logic :='0';
	signal w_n_VDUCS					: std_logic :='1';
	signal w_n_ACIACS					: std_logic :='1';
	signal n_externalRam1CS			: std_logic :='1';
	signal w_wait_cnt					: std_logic_vector(3 downto 0) := "0000";
	signal w_cpuclken					: std_logic :='0';

	-- Data sources into CPU
	signal w_MonROMData				: std_logic_vector(15 downto 0);
	signal w_sramDataOut				: std_logic_vector(15 downto 0);
	signal w_sram2DataOut			: std_logic_vector(15 downto 0);
	signal w_sram3DataOut			: std_logic_vector(15 downto 0);
	signal w_extSramDataOut			: std_logic_vector(15 downto 0);
	signal w_VDUDataOut				: std_logic_vector(7 downto 0);
	signal w_ACIADataOut				: std_logic_vector(7 downto 0);
	signal w_PeriphData				: std_logic_vector(7 downto 0);

	-- CPU clock counts
	signal w_cpuCount					: std_logic_vector(5 downto 0); 
	signal w_cpuClock					: std_logic;
	signal w_resetLow					: std_logic := '1';

   -- Serial clock enables
	signal w_serialCount         	: std_logic_vector(15 downto 0) := x"0000";
   signal w_serialCount_d       	: std_logic_vector(15 downto 0);
   signal w_serialEn            	: std_logic;
	
begin

	-- Debounce the reset line
	DebounceResetSwitch	: entity work.debounce
	port map (
		clk		=> i_CLOCK_50,
		button	=> n_reset,
		result	=> w_resetLow
	);
	
	IO_PIN(48) <= w_cpuClock;
	IO_PIN(47) <= n_WR;
	IO_PIN(46) <= w_nLDS;
	IO_PIN(45) <= w_nUDS;
	IO_PIN(44) <= n_externalRam1CS;
	IO_PIN(43) <= w_wait_cnt(3);
	IO_PIN(42) <= '0';
	IO_PIN(41) <= '0';
	IO_PIN(40) <= '0';
	IO_PIN(39) <= '0';
	IO_PIN(38) <= '0';
	IO_PIN(37) <= '0';
	IO_PIN(36) <= '0';
	IO_PIN(35) <= '0';
	IO_PIN(34) <= '0';
	IO_PIN(33) <= '0';
	IO_PIN(32) <= '0';
	IO_PIN(31) <= '0';
	IO_PIN(30) <= '0';
	IO_PIN(29) <= '0';
	IO_PIN(28) <= '0';
	IO_PIN(27) <= '0';
	IO_PIN(26) <= '0';
	IO_PIN(25) <= '0';
	IO_PIN(24) <= '0';
	IO_PIN(23) <= '0';
	IO_PIN(22) <= '0';
	IO_PIN(21) <= '0';
	IO_PIN(20) <= '0';
	IO_PIN(19) <= '0';
	IO_PIN(18) <= '0';
	IO_PIN(17) <= '0';
	IO_PIN(16) <= '0';
	IO_PIN(15) <= '0';
	IO_PIN(14) <= '0';
	IO_PIN(13) <= '0';
	IO_PIN(12) <= '0';
	IO_PIN(11) <= '0';
	IO_PIN(10) <= '0';
	IO_PIN(9) <= '0';
	IO_PIN(8) <= '0';
	IO_PIN(7) <= '0';
	IO_PIN(6) <= '0';
	IO_PIN(5) <= '0';
	IO_PIN(4) <= '0';
	IO_PIN(3) <= '0';

	-- ____________________________________________________________________________________
	-- 68000 CPU
	
	-- Wait states for external SRAM
	w_cpuclken <= 	n_externalRam1CS or ((not n_externalRam1CS) and w_wait_cnt(3));
						
	-- Wait states for external SRAM
	process (i_CLOCK_50,n_externalRam1CS)
		begin
			if rising_edge(i_CLOCK_50) then
			  if n_externalRam1CS = '0' then
				  w_wait_cnt <= w_wait_cnt + 1;
			  else
					w_wait_cnt <= "0000";
			  end if;
			end if;
		end process;
	
--	waitCount : entity work.GrayCounter
--		port map (
--			Clk		=> i_CLOCK_50,
--			Rst		=> n_externalRam1CS,
--			En			=> not n_externalRam1CS,
--			output	=> w_wait_cnt
--		);
	
	CPU68K : entity work.TG68KdotC_Kernel
		port map (
			clk				=> w_cpuClock,
			nReset			=> w_resetLow,
			clkena_in		=> w_cpuclken,
			data_in			=> cpuDataIn,
			IPL				=> "111",
			IPL_autovector => '0',
			berr				=> '0',
			CPU				=> "00",				-- 68000 CPU
			addr				=> cpuAddress,
			data_write		=> cpuDataOut,
			nWr				=> n_WR,
			nUDS				=> w_nUDS,			-- D8..15 select
			nLDS				=> w_nLDS,			-- D0..7 - select
			busstate			=> w_busstate,		-- 
			nResetOut		=> w_nResetOut,
			FC					=> w_FC,
			clr_berr			=> w_clr_berr
		); 
	
	-- ____________________________________________________________________________________
	-- BUS ISOLATION

	cpuDataIn <=
		w_VDUDataOut  & w_VDUDataOut	when w_n_VDUCS 			= '0' else	-- Copy 8-bit peripheral reads to both halves of the data bus
		w_ACIADataOut & w_ACIADataOut	when w_n_ACIACS			= '0' else	-- Copy 8-bit peripheral reads to both halves of the data bus
		w_MonROMData						when w_n_RomCS				= '0' else	-- ROM
		w_sramDataOut						when w_n_RamCS				= '0' else	-- Internal SRAM
		w_sram2DataOut						when w_n_Ram2CS			= '0' else	-- Internal SRAM
		w_sram3DataOut						when w_n_Ram3CS			= '0' else	-- Internal SRAM
		sramData&sramData			 		when n_externalRam1CS	= '0' else	-- External SRAM (byte access only)
		x"dead";
	
	-- ____________________________________________________________________________________
	-- TS2 Monitor ROM
	
	w_n_RomCS <=	'0' when (cpuAddress(23 downto 15) = x"00"&'1')	else 		-- x008000-x00BFFF (MAIN EPROM)
						'0' when (cpuAddress(23 downto 3) =  x"00000"&'0')	else		-- X000000-X000007 (VECTORS)
						'1';
	
	rom1 : entity work.Monitor_68K_ROM -- Monitor 16KB (8Kx16)
		port map (
			address 	=> cpuAddress(13 downto 1),
			clock		=> i_CLOCK_50,
			q			=> w_MonROMData
		);
	
	-- ____________________________________________________________________________________
	-- 32KB Internal SRAM
	-- The RAM address input is delayed due to being registered so the gate is the true of the clock not the low level
	
	w_n_RamCS 			<= '0' when ((w_n_RomCS = '1') and (cpuAddress(23 downto 15) = x"00"&'0'))	else	-- x000008-x007fff
								'1';
	w_wrRamStrobe		<= (not n_WR) and (not w_n_RamCS) and (w_cpuClock);
	w_WrRamByteEn(1)	<= (not n_WR) and (not w_nUDS) and (not w_n_RamCS);
	w_WrRamByteEn(0)	<= (not n_WR) and (not w_nLDS) and (not w_n_RamCS);
	
	ram1 : ENTITY work.RAM_16Kx16 -- 32KB (16Kx16)
		PORT map	(
			address		=> cpuAddress(14 downto 1),
			clock			=> i_CLOCK_50,
			data			=> cpuDataOut,
			byteena		=> w_WrRamByteEn,
			wren			=> w_wrRamStrobe,
			q				=> w_sramDataOut
		);
	
	-- ____________________________________________________________________________________
	-- 64KB Internal SRAM
	-- The RAM address input is delayed due to being registered so the gate is the true of the clock not the low level
	
	w_n_Ram2CS 			<= '0' when (cpuAddress(23 downto 16) = x"20")	else	-- x200008-x20ffff
								'1';
	w_wrRam2Strobe		<= (not n_WR) and (not w_n_Ram2CS) and (w_cpuClock);
	w_WrRam2ByteEn(1)	<= (not n_WR) and (not w_nUDS) and (not w_n_Ram2CS);
	w_WrRam2ByteEn(0)	<= (not n_WR) and (not w_nLDS) and (not w_n_Ram2CS);
	
	ram2 : ENTITY work.RAM_32Kx16 -- 64KB (32Kx16)
		PORT map	(
			address		=> cpuAddress(15 downto 1),
			clock			=> i_CLOCK_50,
			data			=> cpuDataOut,
			byteena		=> w_WrRam2ByteEn,
			wren			=> w_wrRam2Strobe,
			q				=> w_sram2DataOut
		);
	
	-- ____________________________________________________________________________________
	-- 32KB Internal SRAM
	-- The RAM address input is delayed due to being registered so the gate is the true of the clock not the low level
	
	w_n_Ram3CS 			<= '0' when (cpuAddress(23 downto 15) = x"21"&'0')	else	-- x210008-x217fff
								'1';
	w_wrRam3Strobe		<= (not n_WR) and (not w_n_Ram3CS) and (w_cpuClock);
	w_WrRam3ByteEn(1)	<= (not n_WR) and (not w_nUDS) and (not w_n_Ram3CS);
	w_WrRam3ByteEn(0)	<= (not n_WR) and (not w_nLDS) and (not w_n_Ram3CS);
	
	ram3 : ENTITY work.RAM_16Kx16 -- 32KB (16Kx16)
		PORT map	(
			address		=> cpuAddress(14 downto 1),
			clock			=> i_CLOCK_50,
			data			=> cpuDataOut,
			byteena		=> w_WrRam3ByteEn,
			wren			=> w_wrRam3Strobe,
			q				=> w_sram3DataOut
		);
		
	-- 1MB External SRAM (can only be accessed as bytes) - no dynamic bus sizin
	n_externalRam1CS <= '0' when ((cpuAddress(23 downto 20) = x"3") and ((w_nLDS = '0') or (w_nUDS = '0')))	else	-- x30000-x3fffff (every other location)
							  '1';
	sramAddress(19 downto 1) <= cpuAddress(19 downto 1);
	sramAddress(0) <= w_nLDS;
	sramData <= cpuDataOut(7 downto 0) when ((w_nUDS = '0') and (n_WR = '0')) else 
					cpuDataOut(7 downto 0) when ((w_nLDS = '0') and (n_WR = '0')) else
					(others => 'Z');
	
	n_sRamWE <= n_WR or n_externalRam1CS or (w_nLDS and w_nUDS);
	n_sRamOE <= (not n_WR) or n_externalRam1CS;
	n_sRamCS <= n_externalRam1CS;
	
	-- Route the data to the peripherals
	w_PeriphData <= 	cpuDataOut(15 downto 8)	when (w_nUDS = '0') else
							cpuDataOut(7 downto 0)  when (w_nLDS = '0') else
							x"00";
							
	-- ____________________________________________________________________________________
	-- INPUT/OUTPUT DEVICES
	-- Grant Searle's VGA driver
	
	w_n_VDUCS <= '0' when ((cpuAddress(23 downto 4) = x"01004") and (w_nUDS = '0') and (serSelect = '1'))	 else -- x01004X - Based on monitor.lst file ACIA address
					 '0' when ((cpuAddress(23 downto 4) = x"01004") and (w_nLDS = '0') and (serSelect = '0'))	 else 
					 '1';
	
	VDU : entity work.SBCTextDisplayRGB
		port map (
			n_reset	=> w_resetLow,
			clk		=> i_CLOCK_50,
			
			-- RGB CompVideo signals
			hSync		=> hSync,
			vSync		=> vSync,
			videoR0	=> videoR0,
			videoR1	=> videoR1,
			videoG0	=> videoG0,
			videoG1	=> videoG1,
			videoB0	=> videoB0,
			videoB1	=> videoB1,
			n_wr		=> w_n_VDUCS or      n_WR or w_cpuClock,
			n_rd		=> w_n_VDUCS or (not n_WR),
			n_int		=> w_n_IRQ5,
			regSel	=> cpuAddress(1),
			dataIn	=> w_PeriphData,
			dataOut	=> w_VDUDataOut,
			ps2clk	=> ps2Clk,
			ps2Data	=> ps2Data
		);
	
	-- Neal Crook's bufferedUART - uses clock enables
	
	w_n_ACIACS <= '0' when ((cpuAddress(23 downto 4) = x"01004") and (w_nLDS = '0') and (serSelect = '1')) else -- x01004X - Based on monitor.lst file ACIA address
					  '0' when ((cpuAddress(23 downto 4) = x"01004") and (w_nUDS = '0') and (serSelect = '0')) else
					  '1';
							
	ACIA : entity work.bufferedUART
		port map(
			clk		=> i_CLOCK_50, 
			n_wr		=> w_n_ACIACS or      n_WR  or w_cpuClock,
			n_rd		=> w_n_ACIACS or (not n_WR),
			n_int		=> w_n_IRQ6,
			regSel	=> cpuAddress(1),
			dataIn	=> w_PeriphData,
			dataOut	=> w_ACIADataOut,
			rxClkEn	=> w_serialEn,
			txClkEn	=> w_serialEn,			
			rxd		=> rxd1,
			txd		=> txd1,
			n_cts		=> cts1,
			n_rts		=> rts1
		);
	

	-- ____________________________________________________________________________________
	-- SYSTEM CLOCKS
	
	process (i_CLOCK_50)
		begin
			if rising_edge(i_CLOCK_50) then
				if w_cpuCount < 2 then -- 4 = 10MHz, 3 = 12.5MHz, 2=16.6MHz, 1=25MHz
					w_cpuCount <= w_cpuCount + 1;
				else
					w_cpuCount <= (others=>'0');
				end if;
				if w_cpuCount < 2 then -- 2 when 10MHz, 2 when 12.5MHz, 2 when 16.6MHz, 1 when 25MHz
					w_cpuClock <= '0';
				else
					w_cpuClock <= '1';
				end if;
			end if;
		end process;
	
	
	-- Baud Rate CLOCK SIGNALS
	-- 2416 = 115,200 baud
	
	baud_div: process (w_serialCount_d, w_serialCount)
		 begin
			  w_serialCount_d <= w_serialCount + 2416;
		 end process;

	process (i_CLOCK_50)
		begin
			if rising_edge(i_CLOCK_50) then
			  -- Enable for baud rate generator
			  w_serialCount <= w_serialCount_d;
			  if w_serialCount(15) = '0' and w_serialCount_d(15) = '1' then
					w_serialEn <= '1';
			  else
					w_serialEn <= '0';
			  end if;
			end if;
		end process;

end;
