 %include "boot.inc"
 section loader vstart=LOADER_BASE_ADDR
 LOADER_STACK_TOP equ LOADER_BASE_ADDR
 jmp loader_start
 
  ;构建 gdt 及其内部的描述符
   GDT_BASE: dd 0x00000000
             dd 0x00000000

   CODE_DESC: dd 0x0000FFFF
              dd DESC_CODE_HIGH4

   DATA_STACK_DESC: dd 0x0000FFFF
                    dd DESC_DATA_HIGH4
   
   VIDEO_DESC: dd 0x80000007 ;limit=(0xbffff-0xb8000)/4k=0x7
               dd DESC_VIDEO_HIGH4  ;此时 dpl 为 0

    GDT_SIZE  equ $ - GDT_BASE
    GDT_LIMIT equ GDT_SIZE - 1
    times 60 dq 0 ; 此处预留 60 个描述符的空位
    SELECTOR_CODE equ (0x0001<<3) + TI_GDT + RPL0 ; 相当于(CODE_DESC - GDT_BASE)/8 + TI_GDT + RPL0
    SELECTOR_DATA equ (0x0002<<3) + TI_GDT + RPL0; 同上
    SELECTOR_VIDEO equ (0x0003<<3) + TI_GDT + RPL0; 同上
    
    ; total_mem_bytes 用于保存内存容量,以字节为单位,此位置比较好记
    ; 当前偏移 loader.bin 文件头 0x200 字节
    ; loader.bin 的加载地址是 0x900
    ; 故 total_mem_bytes 内存中的地址是 0xb00   ;jmp三字节，0xb03
 ; 将来在内核中咱们会引用此地址
    total_mem_bytes dd 0

 ;以下是 gdt 的指针,前 2 字节是 gdt 界限,后 4 字节是 gdt 起始地址

    gdt_ptr dw GDT_LIMIT
            dd GDT_BASE

;人工对齐:total_mem_bytes4+gdt_ptr6+ards_buf244+ards_nr2,共 256 字节
    ards_buf times 244 db 0
    ards_nr dw 0     ;用于记录 ARDS 结构体数量
    

    loader_start:

    mov sp,LOADER_BASE_ADDR                                   ;先初始化了栈指针
    xor ebx,ebx                                               ;异或自己 即等于0
    mov ax,0                                       
    mov es,ax                                                 ;心有不安 还是把es给初始化一下
    mov di,ards_buf                                           ;di指向缓冲区位置
.e820_mem_get_loop:
    mov eax,0x0000E820                                            ;每次都需要初始化
    mov ecx,0x14
    mov edx,0x534d4150
    int 0x15
    jc .e820_failed_so_try_e801
   ;若 cf 位为 1 则有错误发生,尝试 0xe801 子功能

   add di, cx  ;使 di 增加 20 字节指向缓冲区中新的 ARDS 结构位置
   inc word [ards_nr]   ;记录 ARDS 数量
   cmp ebx, 0  ;若 ebx 为 0 且 cf 不为 1,这说明 ards 全部返回当前已是最后一个
   jnz .e820_mem_get_loop
   
   ;在所有 ards 结构中
   ;找出(base_add_low + length_low)的最大值,即内存的容量

   mov cx,[ards_nr]
   ;遍历每一个 ARDS 结构体,循环次数是 ARDS 的数量
   mov ebx, ards_buf
   xor edx, edx     ;edx 为最大的内存容量,在此先清 0
  .find_max_mem_area:
;无需判断 type 是否为 1,最大的内存块一定是可被使用的
   mov eax, [ebx]   ;base_add_low
   add eax, [ebx+8] ;length_low
   add ebx,20       ;指向缓冲区中下一个 ARDS 结构
   cmp edx, eax
;冒泡排序,找出最大,edx 寄存器始终是最大的内存容量
   jge .next_ards ;大于或等于
   mov edx, eax   ;edx 为总内存大小
.next_ards:
   loop .find_max_mem_area
   jmp .mem_get_ok

;------ int 15h ax = E801h 获取内存大小,最大支持 4G ------
; 返回后, ax cx 值一样,以 KB 为单位,bx dx 值一样,以 64KB 为单位
; 在 ax 和 cx 寄存器中为低 16MB,在 bx 和 dx 寄存器中为 16MB 到 4GB
.e820_failed_so_try_e801:
    mov ax,0xe801
    int 0x15
    jc .e801_failed_so_trye88 ;若当前 e801 方法失败,就尝试 0x88 方法

;1 先算出低 15MB 的内存
; ax 和 cx 中是以 KB 为单位的内存数量,将其转换为以 byte 为单位
    mov cx,0x400    ;cx 和 ax 值一样,cx 用作乘数
    mul cx
    shl edx,16
    and eax,0x0000FFFF
    or edx,eax
    add edx, 0x100000    ;ax 只是 15MB,故要加 1MB
    mov esi,edx          ;先把低 15MB 的内存容量存入 esi 寄存器备份

;2 再将 16MB 以上的内存转换为 byte 为单位
; 寄存器 bx 和 dx 中是以 64KB 为单位的内存数量
    xor eax,eax
    mov ax,bx
    mov ecx, 0x10000  ;0x10000 十进制为 64KB
    mul ecx   ;32 位乘法,默认的被乘数是 eax,积为 64 位,高 32 位存入 edx,低 32 位存入 eax
    add esi,eax  ;由于此方法只能测出 4GB 以内的内存,故 32 位 eax 足够了,edx 肯定为 0,只加 eax 便可
    mov edx,esi   ;edx 为总内存大小
    jmp .mem_get_ok

;----- int 15h ah = 0x88 获取内存大小,只能获取 64MB 之内 -----
.e801_failed_so_trye88:
    ;int 15 后,ax 存入的是以 KB 为单位的内存容量
    mov ah, 0x88
    int 0x15
    jc .error_hlt
    and eax,0x0000FFFF  ;16 位乘法,被乘数是 ax,积为 32 位。积的高 16 位在 dx 中,积的低 16 位在 ax 中
    mov cx,0x400        ;0x400 等于 1024,将 ax 中的内存容量换为以 byte 为单位
    mul cx
    shl edx,16          
    or edx,eax     ;把 dx 移到高 16 位,为 32 位的积
    add edx,0x100000    ;0x88 子功能只会返回 1MB 以上的内存,故实际内存大小要加上 1MB
.error_hlt:
    jmp $
.mem_get_ok:
    mov [total_mem_bytes], edx

;将内存换为 byte 单位后存入 total_mem_bytes 处


;-------------------- 准备进入保护模式 -------------------------------
 ;1 打开 A20
 ;2 加载 gdt
 ;3 将 cr0 的 pe 位置 1

 ;----------------- 打开 A20 ----------------

 in al,0x92
 or al,0000_0010B
 out 0x92,al
 ;----------------- 加载 GDT ----------------
 lgdt [gdt_ptr]
 ;---------------- cr0 第 0 位置 1 ----------------
 mov eax, cr0
 or eax, 0x00000001
 mov cr0, eax

 jmp dword SELECTOR_CODE:p_mode_start ; 刷新流水线

 [bits 32]
 p_mode_start:
    mov ax, SELECTOR_DATA
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov esp,LOADER_STACK_TOP
    mov ax,SELECTOR_VIDEO
    mov gs,ax

    mov byte [gs:160],'P'

    jmp $
   

      
