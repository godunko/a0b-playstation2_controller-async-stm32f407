--
--  Copyright (C) 2024, Vadim Godunko
--
--  SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
--

--  It is expected that STM32F407 chip is runnung at 168MHz.
--  SPI1 peripheral is on APB2 bus and clocked at 84 MHz.
--  TIM7 peripheral is on APB1 bus and clocked at 2*42 = 84 MHz.
--
--  Use of 256 prescaler for SPI result communication at 328.125 KBit/s,
--  and it should be less that 500 KBit/s.
--
--  Timer is used to delays after lowering of NSS and starting of
--  transmission (20 usec), as well as to detect communication timeout
--  (100 usec). Timer's prescaler value is fixed to 0, it means that it
--  counts at 42 MHz. Autoreload values are set to 1_680 (for 20 usec
--  delay), and to 8_400 (for 100 usec timeout).

pragma Ada_2022;

with Ada.Synchronous_Task_Control; use Ada.Synchronous_Task_Control;
with Ada.Interrupts.Names;

with A0B.ARMv7M.CMSIS;
with A0B.SVD.STM32F407.DBG;        use A0B.SVD.STM32F407.DBG;
with A0B.SVD.STM32F407.EXTI;       use A0B.SVD.STM32F407.EXTI;
with A0B.SVD.STM32F407.GPIO;       use A0B.SVD.STM32F407.GPIO;
with A0B.SVD.STM32F407.RCC;        use A0B.SVD.STM32F407.RCC;
with A0B.SVD.STM32F407.SPI;        use A0B.SVD.STM32F407.SPI;
with A0B.SVD.STM32F407.SYSCFG;     use A0B.SVD.STM32F407.SYSCFG;
with A0B.SVD.STM32F407.TIM;        use A0B.SVD.STM32F407.TIM;

package body Driver is

   Prescale_TIM_PSC : constant := 0;
   Delay_TIM_ARR    : constant := 1_680;
   Timeout_TIM_ARR  : constant := 8_400;
   --  Values of timer's configuration, see description at the top of the file.

   --  Delay_Done : Boolean := False with Volatile;

   Active_Buffer : Unsigned_8_Array (1 .. 32);
   Current       : Natural := 0;
   Remaining     : Natural := 0;
   Ready         : Suspension_Object;

   protected Handler is

      procedure Initialize;

      procedure EXTI_Handler
        with Attach_Handler => Ada.Interrupts.Names.EXTI3_Interrupt;

      procedure TIM_Handler
        with Attach_Handler => Ada.Interrupts.Names.TIM7_Interrupt;

      procedure SPI_Handler
        with Attach_Handler => Ada.Interrupts.Names.SPI1_Interrupt;

   end Handler;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is

      procedure Configure_PIO;
      procedure Configure_SPI;
      procedure Configure_TIM;
      procedure Configure_EXTI;

      --------------------
      -- Configure_EXTI --
      --------------------

      procedure Configure_EXTI is
      begin
         SYSCFG_Periph.EXTICR1.EXTI.Arr (3) := 2#0000#;
         --  Select the source input for the EXTI3 - PA3

         EXTI_Periph.RTSR.TR.Arr (3) := True;
         --  Rising trigger enabled (for Event and Interrupt) for input line
         EXTI_Periph.FTSR.TR.Arr (3) := False;
         --  Falling trigger disabled (for Event and Interrupt) for input line
      end Configure_EXTI;

      -------------------
      -- Configure_PIO --
      -------------------

      procedure Configure_PIO is
      begin
         --  A3, ACK

         GPIOA_Periph.MODER.Arr (3)   := 2#00#;  --  General purpose input mode
         GPIOA_Periph.OSPEEDR.Arr (3) := 2#11#;  --  Very high speed
         GPIOA_Periph.PUPDR.Arr (3)   := 2#01#;  --  Pull up

         --  A4, NSS

         GPIOA_Periph.MODER.Arr (4)   := 2#01#;
         --  General purpose output mode
         GPIOA_Periph.OSPEEDR.Arr (4) := 2#11#;
         GPIOA_Periph.BSRR.BS.Arr (4) := True;   --  Set NSS

         --  A5, SCK

         GPIOA_Periph.MODER.Arr (5)   := 2#10#;    --  Alternate function mode
         GPIOA_Periph.OSPEEDR.Arr (5) := 2#11#;    --  Very high speed
         GPIOA_Periph.AFRL.Arr (5)    := 2#0101#;  --  Alternate function 5

         --  A6, MISO

         GPIOA_Periph.MODER.Arr (6)   := 2#10#;    --  Alternate function mode
         GPIOA_Periph.OSPEEDR.Arr (6) := 2#11#;    --  Very high speed
         GPIOA_Periph.AFRL.Arr (6)    := 2#0101#;  --  Alternate function 5
         GPIOA_Periph.PUPDR.Arr (6)   := 2#01#;    --  Pull up

         --  A7, MOSI

         GPIOA_Periph.MODER.Arr (7)   := 2#10#;    --  Alternate function mode
         GPIOA_Periph.OSPEEDR.Arr (7) := 2#11#;    --  Very high speed
         GPIOA_Periph.AFRL.Arr (7)    := 2#0101#;  --  Alternate function 5
      end Configure_PIO;

      -------------------
      -- Configure_SPI --
      -------------------

      procedure Configure_SPI is
      begin
         SPI1_Periph.CR1.SPE := False;

         SPI1_Periph.CR1 :=
           (CPHA     => True,
            --  The second clock transition is the first data capture edge
            CPOL     => True,   --  CK to 1 when idle
            MSTR     => True,
            BR       => 7,      --  fPCLK/256
            SPE      => False,
            LSBFIRST => True,   --  LSB transmitted first
            SSI      => True,
            SSM      => False,  --  Software slave management disabled
            RXONLY   => False,
            DFF      => False,
            CRCNEXT  => False,
            CRCEN    => False,  --  CRC calculation disabled
            BIDIOE   => False,
            BIDIMODE => False,
            others   => <>);

         SPI1_Periph.CR2 :=
           (RXDMAEN => False,
            TXDMAEN => False,
            SSOE    => True,
            --  SS output is enabled in master mode and when the cell is
            --  enabled.
            FRF     => False,  --  SPI Motorola mode
            ERRIE   => False,
            RXNEIE  => False,
            TXEIE   => False,
            others  => <>);

         SPI1_Periph.I2SCFGR.I2SMOD := False;

         SPI1_Periph.CR1.SPE := True;
      end Configure_SPI;

      -------------------
      -- Configure_TIM --
      -------------------

      procedure Configure_TIM is
      begin
         TIM7_Periph.CR1 :=
           (CEN    => False,  --  Counter disabled
            UDIS   => False,  --  UEV enabled
            URS    => True,
            --  Only counter overflow/underflow generates an update interrupt
            --  or DMA request if enabled.
            OPM    => True,
            --  Counter stops counting at the next update event (clearing the
            --  CEN bit).
            ARPE   => False,
            others => <>);

         TIM7_Periph.PSC :=
           (PSC    => Prescale_TIM_PSC,
            others => <>);

         TIM7_Periph.DIER :=
           (UIE    => True,   --  Update interrupt enabled.
            UDE    => False,  --  Update DMA request disabled.
            others => <>);

         --  Stop timer on debug breakpoint

         DBG_Periph.DBGMCU_APB1_FZ.DBG_TIM7_STOP := True;
      end Configure_TIM;

   begin
      --  Enable peripheral clocks.

      RCC_Periph.AHB1ENR.GPIOAEN  := True;
      RCC_Periph.APB2ENR.SYSCFGEN := True;
      RCC_Periph.APB2ENR.SPI1EN   := True;
      RCC_Periph.APB1ENR.TIM7EN   := True;
      A0B.ARMv7M.CMSIS.Data_Synchronization_Barrier;
      --  Wait till completion of all writes, see STM32F407 Errata sheet
      --  2.2.13 Delay after an RCC peripheral clock enabling

      --  Reset peripherals, it is useful for debugging.

      RCC_Periph.AHB1RSTR.GPIOARST  := True;
      RCC_Periph.APB2RSTR.SYSCFGRST := True;
      RCC_Periph.APB2RSTR.SPI1RST   := True;
      RCC_Periph.APB1RSTR.TIM7RST   := True;
      A0B.ARMv7M.CMSIS.Data_Synchronization_Barrier;
      RCC_Periph.AHB1RSTR.GPIOARST  := False;
      RCC_Periph.APB2RSTR.SYSCFGRST := False;
      RCC_Periph.APB2RSTR.SPI1RST   := False;
      RCC_Periph.APB1RSTR.TIM7RST   := False;
      A0B.ARMv7M.CMSIS.Data_Synchronization_Barrier;

      --  Configure peripherals.

      Configure_SPI;
      Configure_PIO;
      Configure_TIM;
      Configure_EXTI;

      Handler.Initialize;
   end Initialize;

   -------------
   -- Handler --
   -------------

   protected body Handler is

      ------------------
      -- EXTI_Handler --
      ------------------

      procedure EXTI_Handler is
      begin
         --  Pending state must be cleared by software. Also, disable
         --  interrupt, otherwise it might be triggered when number of bytes
         --  is less than expected by the controller.
         --
         --  XXX Is it wrong expectation and actual length of the data should
         --  be computed from the second received byte?

         EXTI_Periph.PR.PR.Arr (3)  := True;
         EXTI_Periph.IMR.MR.Arr (3) := False;

         --  Disable timeout.

         TIM7_Periph.CR1.CEN := False;

         --  Enable TXE interrupt to initiate transfer of the next byte.

         SPI1_Periph.CR2.TXEIE := True;
      end EXTI_Handler;

      ----------------
      -- Initialize --
      ----------------

      procedure Initialize is
      begin
         null;
      end Initialize;

      -----------------
      -- SPI_Handler --
      -----------------

      procedure SPI_Handler is
      begin
         if SPI1_Periph.CR2.TXEIE
           and then SPI1_Periph.SR.TXE
         then
            --  Initiate transfer of the byte.

            Current           := @ + 1;
            Remaining         := @ - 1;
            SPI1_Periph.DR.DR := DR_DR_Field (Active_Buffer (Current));

            --  Disable TXE and enable RXNE interrupt.

            SPI1_Periph.CR2.TXEIE  := False;
            SPI1_Periph.CR2.RXNEIE := True;
         end if;

         if SPI1_Periph.SR.RXNE then
            --  Byte has been received, store it in the buffer.

            Active_Buffer (Current) := Unsigned_8 (SPI1_Periph.DR.DR);

            --  Disable SPI.RXNE interrupt

            SPI1_Periph.CR2.RXNEIE := False;

            if Remaining /= 0 then
               --  Enable interrupt on raising edge of the Acknowledge signal

               EXTI_Periph.PR.PR.Arr (3)  := True;
               EXTI_Periph.IMR.MR.Arr (3) := True;

               --  Configure timer for timeout interval and start it.

               TIM7_Periph.ARR.ARR := Timeout_TIM_ARR;
               TIM7_Periph.EGR.UG  := True;
               TIM7_Periph.CR1.CEN := True;

            else
               --  Last byte has been processed.

               Set_True (Ready);
            end if;
         end if;
      end SPI_Handler;

      -----------------
      -- TIM_Handler --
      -----------------

      procedure TIM_Handler is
      begin
         TIM7_Periph.SR.UIF := False;
         --  UIF flag should be reset by software.

         if TIM7_Periph.ARR.ARR = Delay_TIM_ARR then
            --  "Attention" delay is done, enable SPI.TXE interrupt to start
            --  transfer of the first byte.

            SPI1_Periph.CR2.TXEIE := True;

         elsif TIM7_Periph.ARR.ARR = Timeout_TIM_ARR then
            --  Acknoledge timeout, disable EXTI.

            EXTI_Periph.IMR.MR.Arr (3) := False;

            Set_True (Ready);

         else
            raise Program_Error;
         end if;
      end TIM_Handler;

   end Handler;

   ----------
   -- Send --
   ----------

   procedure Send
     (Buffer          : in out Unsigned_8_Array;
      Adaptive_Length : Boolean;
      Last            : out Natural) is
   begin
      Active_Buffer (Buffer'Range) := Buffer;
      Current                      := 0;
      Remaining                    := Buffer'Length;

      GPIOA_Periph.BSRR.BR.Arr (4) := True;  --  Clear bit, NCS

      Set_False (Ready);

      --  Start delay timer

      TIM7_Periph.ARR.ARR := Delay_TIM_ARR;
      TIM7_Periph.EGR.UG  := True;
      TIM7_Periph.CR1.CEN := True;

      Suspend_Until_True (Ready);

      while SPI1_Periph.SR.BSY loop
         null;
      end loop;

      GPIOA_Periph.BSRR.BS.Arr (4) := True;  --  Set bit, NCS

      Last               := Current;
      Buffer (1 .. Last) := Active_Buffer (1 .. Last);
   end Send;

end Driver;