!
! Copyright (C) 2001-2014 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!

! here are the extra terms due to US/PAW pseudos, necessary
! for Ehrenfest dynamics

!-----------------------------------------------------------------------
SUBROUTINE apply_capital_P(npwx, npw, nbnd, evc, P_evc)
  !-----------------------------------------------------------------------
  !
  ! ... Apply the capital P operator (Eq.31-32 od JCP 136, 144103)
  !  
  USE kinds,             ONLY : dp
  USE uspp,              ONLY : vkb, nkb, qq, okvan
  USE cell_base,         ONLY : omega
  USE uspp_param,        ONLY : upf, nh
  USE ions_base,         ONLY : nat, ntyp => nsp, ityp, nsp
  USE gvect,             ONLY : ngm, gg, g, eigts1, eigts2, eigts3, mill
  USE uspp,              ONLY : okvan
  USE uspp_param,        ONLY : upf, lmaxq, nh, nhm
  USE mp_bands,          ONLY : intra_bgrp_comm
  USE mp,                ONLY : mp_sum
  USE becmod,            ONLY : becp
  USE dynamics_module,   ONLY : vel
  USE paw_variables,     ONLY : okpaw
  USE wvfct,             ONLY : igk
  ! -- parameters --------------------------------------------------------
  implicit none
  integer, intent(in) :: npwx, npw, nbnd
  complex(dp), intent(in) :: evc(npwx,nbnd)
  complex(dp), intent(out) :: P_evc(npwx,nbnd,3)
  ! -- local variables ---------------------------------------------------
  integer :: ig, nt, ih, jh, ijh, ipol, na      
  integer :: ikb, jkb, ijkb0, ibnd
  complex(dp):: cfac
  ! work space
  complex(dp), allocatable :: aux1(:,:), qgm(:), ps(:,:)
  complex(dp), allocatable :: dbecp(:,:), vkb1(:,:)
  real(dp) , allocatable :: ddeeq(:,:,:), qmod(:), ylmk0(:,:)
  real(dp), external :: ddot
  
  ! no extra terms in case of norm-conserving
  P_evc = (0.d0,0.d0)
  if (.not. okvan) return
  if (okpaw) call errore('apply_capital_P', 'probably not working with PAWs', 1)
  
  !====================================================================
  ! This is the second term of Eq.32
  !====================================================================
  allocate (aux1(ngm,3))
  allocate (ddeeq(3, (nhm*(nhm+1))/2,nat))
  allocate (qgm(ngm))
  allocate (qmod(ngm))
  allocate (ylmk0(ngm,lmaxq*lmaxq))

  ddeeq(:,:,:) = 0.d0
  call ylmr2(lmaxq*lmaxq, ngm, g, gg, ylmk0)
  qmod(:) = sqrt(gg(:))

  ! here we compute the integral Q for each atom: I = sum_G i G_a exp(-iR.G) Q_nm
  do nt = 1, ntyp
     if (upf(nt)%tvanp) then
        ijh = 1
        do ih = 1, nh(nt)
           do jh = ih, nh(nt)
              call qvan2(ngm, ih, jh, nt, qmod, qgm, ylmk0)
              
              do na = 1, nat
                 if (ityp(na) == nt) then

                    ! The product of structure factor and iG
                    do ig = 1, ngm
                       cfac = conjg(eigts1(mill(1,ig),na) * &
                                    eigts2(mill(2,ig),na) * &
                                    eigts3(mill(3,ig),na))
                       aux1(ig,1) = g(1,ig) * cfac
                       aux1(ig,2) = g(2,ig) * cfac
                       aux1(ig,3) = g(3,ig) * cfac
                    enddo

                    ! The product with the Q functions, G=0 term gives no contribution
                    do ipol = 1, 3
                       ddeeq(ipol,ijh,na) = omega * ddot(2*ngm, aux1(1,ipol), 1, qgm, 1)
                    enddo
                 endif
              enddo  ! na
              ijh = ijh + 1
           enddo  ! jh
        enddo  ! ih
     endif
  enddo  ! nt
  call mp_sum(ddeeq, intra_bgrp_comm)
  deallocate (ylmk0, qgm, qmod, aux1)

  ! multiply by (-i*ionic_velocities)
  do na = 1, nat
     do ipol = 1, 3
        ddeeq(ipol,:,na) = real(ddeeq(ipol,:,na) * (0.d0,-1.d0)*vel(ipol,na),kind=dp)
     enddo
  enddo
  
  ! apply to evc (calbec should alredy be called) 
  allocate(ps(nkb,nbnd))
  do ipol = 1, 3
     ps(:,:) = (0.d0,0.d0)
     ijkb0 = 0
     do nt = 1, nsp
        if (upf(nt)%tvanp) then
           ijh = 1
           do na = 1, nat
              if (ityp(na) == nt) then
                 do ibnd = 1, nbnd
                    do jh = 1, nh(nt)
                       jkb = ijkb0 + jh
                       do ih = 1, nh(nt)
                          ikb = ijkb0 + ih
                          ps(ikb,ibnd) = ps(ikb,ibnd) + ddeeq(ipol,ijh,na) * becp%k(jkb,ibnd)
                       enddo
                    enddo
                 enddo
                 ijkb0 = ijkb0 + nh(nt)
              endif
           enddo
           ijh = ijh + 1
        else
           do na = 1, nat
              if (ityp(na) == nt) ijkb0 = ijkb0 + nh(nt)
           enddo
        endif
     enddo
     if (nbnd == 1) then
        call zgemv('n', npw, nkb, (1.d0,0.d0), vkb, npwx, ps, 1, (1.d0,0.d0), P_evc(ipol,1,1), 1)
     else
        call zgemm('n', 'n', npw, nbnd, nkb, (1.d0,0.d0), vkb, npwx, ps, nkb, (1.d0,0.d0), P_evc(ipol,1,1), npwx)
     endif
  enddo ! ipol

  deallocate(ps, ddeeq)


  !====================================================================
  ! This is the first term of Eq.32
  !====================================================================
  allocate(ps(nkb,nbnd), dbecp(nkb,nbnd), vkb1(npwx,nkb))
  do ipol = 1, 3
     ! derivative of the projector
     do jkb = 1, nkb
        do ig = 1, npw
           vkb1(ig,jkb) = vkb(ig,jkb)*(0.d0,-1.d0)*g(ipol,igk(ig))
        enddo
     enddo
     if (nkb > 0) &
        call zgemm('C', 'N', nkb, nbnd, npw, (1.d0,0.d0), &
                   vkb1, npwx, evc, npwx, (0.d0,0.d0), dbecp, nkb)

     ps = (0.d0,0.d0)
     ijkb0 = 0
     do nt = 1, nsp
        if (upf(nt)%tvanp) then
           do na = 1, nat
              if (ityp(na) == nt) then
                 do ibnd = 1, nbnd
                    do jh = 1, nh(nt)
                       jkb = ijkb0 + jh
                       do ih = 1, nh(nt)
                          ikb = ijkb0 + ih
                          ps(ikb,ibnd) = ps(ikb,ibnd) + (0.d0,-1.d0)*vel(ipol,na) * &
                                         qq(ih,jh,nt) * dbecp(jkb,ibnd)
                       enddo
                    enddo
                 enddo
                 ijkb0 = ijkb0 + nh(nt)
              endif
           enddo
        else
          do na = 1, nat
             if (ityp(na) == nt) ijkb0 = ijkb0 + nh(nt)
          enddo
        endif
     enddo
     if (nbnd == 1) then
        call zgemv('n', npw, nkb, (1.d0,0.d0), vkb, npwx, ps, 1, (1.d0,0.d0), P_evc(ipol,1,1), 1)
     else
        call zgemm('n', 'n', npw, nbnd, nkb, (1.d0,0.d0), vkb, npwx, ps, nkb, (1.d0,0.d0), P_evc(ipol,1,1), npwx)
     endif
  enddo ! ipol

  deallocate(ps, dbecp, vkb1)

    
  return
  
END SUBROUTINE apply_capital_P
