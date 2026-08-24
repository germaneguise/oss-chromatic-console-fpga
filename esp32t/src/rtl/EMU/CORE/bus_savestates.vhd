-----------------------------------------------------------------
--------------- Bus Package --------------------------------
-----------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

package pBus_savestates is

   constant BUS_buswidth : integer := 64;
   constant BUS_busadr   : integer := 10;
   
   type regmap_type is record
      Adr         : integer range 0 to (2**BUS_busadr)-1;
      upper       : integer range 0 to BUS_buswidth-1;
      lower       : integer range 0 to BUS_buswidth-1;
      size        : integer range 0 to (2**BUS_busadr)-1;
      def     : std_logic_vector(BUS_buswidth-1 downto 0);
   end record;
  
end package;

-----------------------------------------------------------------
--------------- Reg Interface, verbose for Verilog --------------
-----------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;  

library work;
use work.pBus_savestates.all;

entity eReg_SavestateV is
   generic
   (
      index     : integer := 0;
      Adr       : integer range 0 to (2**BUS_busadr)-1;
      upper     : integer range 0 to BUS_buswidth-1;
      lower     : integer range 0 to BUS_buswidth-1;
      def       : std_logic_vector(BUS_buswidth-1 downto 0)
   );
   port 
   (
      clk       : in    std_logic;
      BUS_Din   : in    std_logic_vector(BUS_buswidth-1 downto 0);
      BUS_Adr   : in    std_logic_vector(BUS_busadr-1 downto 0);
      BUS_wren  : in    std_logic;
      BUS_rst   : in    std_logic;
      BUS_Dout  : out   std_logic_vector(BUS_buswidth-1 downto 0) := (others => '0');
      Din       : in    std_logic_vector(upper downto lower);
      Dout      : out   std_logic_vector(upper downto lower)
   );
end entity;

-- EXPERIMENT STUB: the savestate bus master (gb_savestates) is inert in this
-- design, so every instance's Dout_buffer can only ever hold `def`. This
-- architecture states that outright - Dout is the constant default, the bus
-- register and readback muxes are gone at the source. Comparing per-module
-- synthesis area against the real architecture measures exactly how much
-- savestate logic the optimizer fails to remove on its own.
architecture arch of eReg_SavestateV is

begin

   Dout     <= def(upper downto lower);
   BUS_Dout <= (others => '0');

end architecture;

-----------------------------------------------------------------
--------------- Reg Interface, nonverbose -----------------------
-----------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;  

library work;
use work.pBus_savestates.all;

entity eReg_Savestate is
   generic
   (
      Reg       : regmap_type;
      index     : integer := 0
   );
   port 
   (
      clk       : in    std_logic;
      BUS_Din   : in    std_logic_vector(BUS_buswidth-1 downto 0);
      BUS_Adr   : in    std_logic_vector(BUS_busadr-1 downto 0);
      BUS_wren  : in    std_logic;
      BUS_rst   : in    std_logic;
      BUS_Dout  : out   std_logic_vector(BUS_buswidth-1 downto 0) := (others => '0');
      Din       : in    std_logic_vector(Reg.upper downto Reg.lower);
      Dout      : out   std_logic_vector(Reg.upper downto Reg.lower)
   );
end entity;

architecture arch of eReg_Savestate is
    
begin

	iReg_SavestateV : entity work.eReg_SavestateV
   generic map
   (
		index => index,
		Adr   => Reg.Adr,  
		upper => Reg.upper,
		lower => Reg.lower,
		def   => Reg.def  
   )
   port map
   (
      clk       => clk,     
      BUS_Din   => BUS_Din, 
      BUS_Adr   => BUS_Adr, 
      BUS_wren  => BUS_wren,
      BUS_rst   => BUS_rst, 
      BUS_Dout  => BUS_Dout,
      Din       => Din,     
      Dout      => Dout    
   );
   
   
end architecture;




